{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-incomplete-record-updates #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Haddock.Backends.Hoogle
-- Copyright   :  (c) Neil Mitchell 2006-2008
-- License     :  BSD-like
--
-- Maintainer  :  haddock@projects.haskell.org
-- Stability   :  experimental
-- Portability :  portable
--
-- Write out Hoogle compatible documentation
-- http://www.haskell.org/hoogle/
-----------------------------------------------------------------------------
module Haddock.Backends.Hoogle (
    ppHoogle
  ) where

import GHC.Types.Basic ( OverlapFlag(..), OverlapMode(..),
                         PromotionFlag(..), TopLevelFlag(..) )
import GHC.Types.SourceText
import GHC.Core.InstEnv (ClsInst(..))
import Documentation.Haddock.Markup
import Haddock.GhcUtils
import Haddock.Types hiding (Version)
import Haddock.Utils hiding (out)

import GHC
import GHC.Driver.Ppr
import GHC.Utils.Outputable as Outputable
import GHC.Utils.Panic
import GHC.Parser.Annotation (IsUnicodeSyntax(..))
import GHC.Unit.State

import Data.Char
import Data.List (intercalate, isPrefixOf)
import Data.Maybe
import Data.Version

import System.Directory
import System.FilePath
prefix :: [String]
prefix = ["-- Hoogle documentation, generated by Haddock"
         ,"-- See Hoogle, http://www.haskell.org/hoogle/"
         ,""]


ppHoogle :: DynFlags -> UnitState -> String -> Version -> String -> Maybe (Doc RdrName) -> [Interface] -> FilePath -> IO ()
ppHoogle dflags unit_state package version synopsis prologue ifaces odir = do
    let -- Since Hoogle is line based, we want to avoid breaking long lines.
        dflags' = dflags{ pprCols = maxBound }
        filename = package ++ ".txt"
        contents = prefix ++
                   docWith dflags' (drop 2 $ dropWhile (/= ':') synopsis) prologue ++
                   ["@package " ++ package] ++
                   ["@version " ++ showVersion version
                   | not (null (versionBranch version)) ] ++
                   concat [ppModule dflags' unit_state i | i <- ifaces, OptHide `notElem` ifaceOptions i]
    createDirectoryIfMissing True odir
    writeUtf8File (odir </> filename) (unlines contents)

ppModule :: DynFlags -> UnitState -> Interface -> [String]
ppModule dflags unit_state iface =
  "" : ppDocumentation dflags (ifaceDoc iface) ++
  ["module " ++ moduleString (ifaceMod iface)] ++
  concatMap (ppExport dflags) (ifaceExportItems iface) ++
  concatMap (ppInstance dflags unit_state) (ifaceInstances iface)


---------------------------------------------------------------------
-- Utility functions

dropHsDocTy :: HsSigType (GhcPass p) -> HsSigType (GhcPass p)
dropHsDocTy = drop_sig_ty
    where
        drop_sig_ty (HsSig x a b)  = HsSig x a (drop_lty b)
        drop_sig_ty x@XHsSigType{} = x

        drop_lty (L src x) = L src (drop_ty x)

        drop_ty (HsForAllTy x a e) = HsForAllTy x a (drop_lty e)
        drop_ty (HsQualTy x a e) = HsQualTy x a (drop_lty e)
        drop_ty (HsBangTy x a b) = HsBangTy x a (drop_lty b)
        drop_ty (HsAppTy x a b) = HsAppTy x (drop_lty a) (drop_lty b)
        drop_ty (HsAppKindTy x a b) = HsAppKindTy x (drop_lty a) (drop_lty b)
        drop_ty (HsFunTy x w a b) = HsFunTy x w (drop_lty a) (drop_lty b)
        drop_ty (HsListTy x a) = HsListTy x (drop_lty a)
        drop_ty (HsTupleTy x a b) = HsTupleTy x a (map drop_lty b)
        drop_ty (HsOpTy x a b c) = HsOpTy x (drop_lty a) b (drop_lty c)
        drop_ty (HsParTy x a) = HsParTy x (drop_lty a)
        drop_ty (HsKindSig x a b) = HsKindSig x (drop_lty a) b
        drop_ty (HsDocTy _ a _) = drop_ty $ unL a
        drop_ty x = x

outHsSigType :: (OutputableBndrId p, NoGhcTcPass p ~ p, XParTy (GhcPass p) ~ NoExtField)
             => DynFlags -> HsSigType (GhcPass p) -> String
outHsSigType dflags = out dflags . reparenSigType . dropHsDocTy


dropComment :: String -> String
dropComment (' ':'-':'-':' ':_) = []
dropComment (x:xs) = x : dropComment xs
dropComment [] = []


outWith :: Outputable a => (SDoc -> String) -> a -> [Char]
outWith p = f . unwords . map (dropWhile isSpace) . lines . p . ppr
    where
        f xs | " <document comment>" `isPrefixOf` xs = f $ drop 19 xs
        f (x:xs) = x : f xs
        f [] = []

out :: Outputable a => DynFlags -> a -> String
out dflags = outWith $ showSDoc dflags

operator :: String -> String
operator (x:xs) | not (isAlphaNum x) && x `notElem` "_' ([{" = '(' : x:xs ++ ")"
operator x = x

commaSeparate :: Outputable a => DynFlags -> [a] -> String
commaSeparate dflags = showSDoc dflags . interpp'SP

---------------------------------------------------------------------
-- How to print each export

ppExport :: DynFlags -> ExportItem GhcRn -> [String]
ppExport dflags ExportDecl { expItemDecl    = L _ decl
                           , expItemPats    = bundledPats
                           , expItemMbDoc   = mbDoc
                           , expItemSubDocs = subdocs
                           , expItemFixities = fixities
                           } = concat [ ppDocumentation dflags dc ++ f d
                                      | (d, (dc, _)) <- (decl, mbDoc) : bundledPats
                                      ] ++
                               ppFixities
    where
        f (TyClD _ d@DataDecl{})  = ppData dflags d subdocs
        f (TyClD _ d@SynDecl{})   = ppSynonym dflags d
        f (TyClD _ d@ClassDecl{}) = ppClass dflags d subdocs
        f (TyClD _ (FamDecl _ d)) = ppFam dflags d
        f (ForD _ (ForeignImport _ name typ _)) = [pp_sig dflags [name] typ]
        f (ForD _ (ForeignExport _ name typ _)) = [pp_sig dflags [name] typ]
        f (SigD _ sig) = ppSig dflags sig
        f _ = []

        ppFixities = concatMap (ppFixity dflags) fixities
ppExport _ _ = []

ppSigWithDoc :: DynFlags -> Sig GhcRn -> [(Name, DocForDecl Name)] -> [String]
ppSigWithDoc dflags sig subdocs = case sig of
    TypeSig _ names t -> concatMap (mkDocSig "" (dropWildCards t)) names
    PatSynSig _ names t -> concatMap (mkDocSig "pattern " t) names
    _ -> []
  where
    mkDocSig leader typ n = mkSubdoc dflags n subdocs
                                     [leader ++ pp_sig dflags [n] typ]

ppSig :: DynFlags -> Sig GhcRn -> [String]
ppSig dflags x  = ppSigWithDoc dflags x []

pp_sig :: DynFlags -> [Located Name] -> LHsSigType GhcRn -> String
pp_sig dflags names (L _ typ)  =
    operator prettyNames ++ " :: " ++ outHsSigType dflags typ
    where
      prettyNames = intercalate ", " $ map (out dflags) names

-- note: does not yet output documentation for class methods
ppClass :: DynFlags -> TyClDecl GhcRn -> [(Name, DocForDecl Name)] -> [String]
ppClass dflags decl subdocs =
  (out dflags decl{tcdSigs=[], tcdATs=[], tcdATDefs=[], tcdMeths=emptyLHsBinds}
    ++ ppTyFams) :  ppMethods
    where

        ppMethods = concat . map (ppSig' . unLoc . add_ctxt) $ tcdSigs decl
        ppSig' = flip (ppSigWithDoc dflags) subdocs

        add_ctxt = addClassContext (tcdName decl) (tyClDeclTyVars decl)

        ppTyFams
            | null $ tcdATs decl = ""
            | otherwise = (" " ++) . showSDoc dflags . whereWrapper $ concat
                [ map pprTyFam (tcdATs decl)
                , map (pprTyFamInstDecl NotTopLevel . unLoc) (tcdATDefs decl)
                ]

        pprTyFam :: LFamilyDecl GhcRn -> SDoc
        pprTyFam (L _ at) = vcat' $ map text $
            mkSubdoc dflags (fdLName at) subdocs (ppFam dflags at)

        whereWrapper elems = vcat'
            [ text "where" <+> lbrace
            , nest 4 . vcat . map (Outputable.<> semi) $ elems
            , rbrace
            ]

ppFam :: DynFlags -> FamilyDecl GhcRn -> [String]
ppFam dflags decl@(FamilyDecl { fdInfo = info })
  = [out dflags decl']
  where
    decl' = case info of
              -- We don't need to print out a closed type family's equations
              -- for Hoogle, so pretend it doesn't have any.
              ClosedTypeFamily{} -> decl { fdInfo = OpenTypeFamily }
              _                  -> decl

ppInstance :: DynFlags -> UnitState -> ClsInst -> [String]
ppInstance dflags unit_state x =
  [dropComment $ outWith (showSDocForUser dflags unit_state alwaysQualify) cls]
  where
    -- As per #168, we don't want safety information about the class
    -- in Hoogle output. The easiest way to achieve this is to set the
    -- safety information to a state where the Outputable instance
    -- produces no output which means no overlap and unsafe (or [safe]
    -- is generated).
    cls = x { is_flag = OverlapFlag { overlapMode = NoOverlap NoSourceText
                                    , isSafeOverlap = False } }

ppSynonym :: DynFlags -> TyClDecl GhcRn -> [String]
ppSynonym dflags x = [out dflags x]

ppData :: DynFlags -> TyClDecl GhcRn -> [(Name, DocForDecl Name)] -> [String]
ppData dflags decl@(DataDecl { tcdDataDefn = defn }) subdocs
    = showData decl{ tcdDataDefn = defn { dd_cons=[],dd_derivs=noLoc [] }} :
      concatMap (ppCtor dflags decl subdocs . unLoc) (dd_cons defn)
    where

        -- GHC gives out "data Bar =", we want to delete the equals.
        -- There's no need to worry about parenthesizing infix data type names,
        -- since this Outputable instance for TyClDecl gets this right already.
        showData d = unwords $ if last xs == "=" then init xs else xs
            where
                xs = words $ out dflags d
ppData _ _ _ = panic "ppData"

-- | for constructors, and named-fields...
lookupCon :: DynFlags -> [(Name, DocForDecl Name)] -> Located Name -> [String]
lookupCon dflags subdocs (L _ name) = case lookup name subdocs of
  Just (d, _) -> ppDocumentation dflags d
  _ -> []

ppCtor :: DynFlags -> TyClDecl GhcRn -> [(Name, DocForDecl Name)] -> ConDecl GhcRn -> [String]
ppCtor dflags dat subdocs con@ConDeclH98 { con_args = con_args' }
  -- AZ:TODO get rid of the concatMap
   = concatMap (lookupCon dflags subdocs) [con_name con] ++ f con_args'
    where
        f (PrefixCon _ args) = [typeSig name $ (map hsScaledThing args) ++ [resType]]
        f (InfixCon a1 a2) = f $ PrefixCon [] [a1,a2]
        f (RecCon (L _ recs)) = f (PrefixCon [] $ map (hsLinear . cd_fld_type . unLoc) recs) ++ concat
                          [(concatMap (lookupCon dflags subdocs . noLoc . extFieldOcc . unLoc) (cd_fld_names r)) ++
                           [out dflags (map (extFieldOcc . unLoc) $ cd_fld_names r) `typeSig` [resType, cd_fld_type r]]
                          | r <- map unLoc recs]

        funs = foldr1 (\x y -> reL $ HsFunTy noExtField (HsUnrestrictedArrow NormalSyntax) x y)
        apps = foldl1 (\x y -> reL $ HsAppTy noExtField x y)

        typeSig nm flds = operator nm ++ " :: " ++
                          outHsSigType dflags (unL $ mkEmptySigType $ funs flds)

        -- We print the constructors as comma-separated list. See GHC
        -- docs for con_names on why it is a list to begin with.
        name = commaSeparate dflags . map unL $ getConNames con

        tyVarArg (UserTyVar _ _ n) = HsTyVar noExtField NotPromoted n
        tyVarArg (KindedTyVar _ _ n lty) = HsKindSig noExtField (reL (HsTyVar noExtField NotPromoted n)) lty
        tyVarArg _ = panic "ppCtor"

        resType = apps $ map reL $
                        (HsTyVar noExtField NotPromoted (reL (tcdName dat))) :
                        map (tyVarArg . unLoc) (hsQTvExplicit $ tyClDeclTyVars dat)

ppCtor dflags _dat subdocs (ConDeclGADT { con_names = names
                                        , con_bndrs = L _ outer_bndrs
                                        , con_mb_cxt = mcxt
                                        , con_g_args = args
                                        , con_res_ty = res_ty })
   = concatMap (lookupCon dflags subdocs) names ++ [typeSig]
    where
        typeSig = operator name ++ " :: " ++ outHsSigType dflags con_sig_ty
        name = out dflags $ map unL names
        con_sig_ty = HsSig noExtField outer_bndrs theta_ty where
          theta_ty = case mcxt of
            Just theta -> noLoc (HsQualTy { hst_xqual = noExtField, hst_ctxt = Just theta, hst_body = tau_ty })
            Nothing -> tau_ty
          tau_ty = foldr mkFunTy res_ty $
            case args of PrefixConGADT pos_args -> map hsScaledThing pos_args
                         RecConGADT (L _ flds) -> map (cd_fld_type . unL) flds
          mkFunTy a b = noLoc (HsFunTy noExtField (HsUnrestrictedArrow NormalSyntax) a b)

ppFixity :: DynFlags -> (Name, Fixity) -> [String]
ppFixity dflags (name, fixity) = [out dflags ((FixitySig noExtField [noLoc name] fixity) :: FixitySig GhcRn)]


---------------------------------------------------------------------
-- DOCUMENTATION

ppDocumentation :: Outputable o => DynFlags -> Documentation o -> [String]
ppDocumentation dflags (Documentation d w) = mdoc dflags d ++ doc dflags w


doc :: Outputable o => DynFlags -> Maybe (Doc o) -> [String]
doc dflags = docWith dflags ""

mdoc :: Outputable o => DynFlags -> Maybe (MDoc o) -> [String]
mdoc dflags = docWith dflags "" . fmap _doc

docWith :: Outputable o => DynFlags -> String -> Maybe (Doc o) -> [String]
docWith _ [] Nothing = []
docWith dflags header d
  = ("":) $ zipWith (++) ("-- | " : repeat "--   ") $
    lines header ++ ["" | header /= "" && isJust d] ++
    maybe [] (showTags . markup (markupTag dflags)) d

mkSubdoc :: DynFlags -> Located Name -> [(Name, DocForDecl Name)] -> [String] -> [String]
mkSubdoc dflags n subdocs s = concatMap (ppDocumentation dflags) getDoc ++ s
 where
   getDoc = maybe [] (return . fst) (lookup (unLoc n) subdocs)

data Tag = TagL Char [Tags] | TagP Tags | TagPre Tags | TagInline String Tags | Str String
           deriving Show

type Tags = [Tag]

box :: (a -> b) -> a -> [b]
box f x = [f x]

str :: String -> [Tag]
str a = [Str a]

-- want things like paragraph, pre etc to be handled by blank lines in the source document
-- and things like \n and \t converted away
-- much like blogger in HTML mode
-- everything else wants to be included as tags, neatly nested for some (ul,li,ol)
-- or inlne for others (a,i,tt)
-- entities (&,>,<) should always be appropriately escaped

markupTag :: Outputable o => DynFlags -> DocMarkup o [Tag]
markupTag dflags = Markup {
  markupParagraph            = box TagP,
  markupEmpty                = str "",
  markupString               = str,
  markupAppend               = (++),
  markupIdentifier           = box (TagInline "a") . str . out dflags,
  markupIdentifierUnchecked  = box (TagInline "a") . str . showWrapped (out dflags . snd),
  markupModule               = \(ModLink m label) -> box (TagInline "a") (fromMaybe (str m) label),
  markupWarning              = box (TagInline "i"),
  markupEmphasis             = box (TagInline "i"),
  markupBold                 = box (TagInline "b"),
  markupMonospaced           = box (TagInline "tt"),
  markupPic                  = const $ str " ",
  markupMathInline           = const $ str "<math>",
  markupMathDisplay          = const $ str "<math>",
  markupUnorderedList        = box (TagL 'u'),
  markupOrderedList          = box (TagL 'o'),
  markupDefList              = box (TagL 'u') . map (\(a,b) -> TagInline "i" a : Str " " : b),
  markupCodeBlock            = box TagPre,
  markupHyperlink            = \(Hyperlink url mLabel) -> box (TagInline "a") (fromMaybe (str url) mLabel),
  markupAName                = const $ str "",
  markupProperty             = box TagPre . str,
  markupExample              = box TagPre . str . unlines . map exampleToString,
  markupHeader               = \(Header l h) -> box (TagInline $ "h" ++ show l) h,
  markupTable                = \(Table _ _) -> str "TODO: table"
  }


showTags :: [Tag] -> [String]
showTags = intercalate [""] . map showBlock


showBlock :: Tag -> [String]
showBlock (TagP xs) = showInline xs
showBlock (TagL t xs) = ['<':t:"l>"] ++ mid ++ ['<':'/':t:"l>"]
    where mid = concatMap (showInline . box (TagInline "li")) xs
showBlock (TagPre xs) = ["<pre>"] ++ showPre xs ++ ["</pre>"]
showBlock x = showInline [x]


asInline :: Tag -> Tags
asInline (TagP xs) = xs
asInline (TagPre xs) = [TagInline "pre" xs]
asInline (TagL t xs) = [TagInline (t:"l") $ map (TagInline "li") xs]
asInline x = [x]


showInline :: [Tag] -> [String]
showInline = unwordsWrap 70 . words . concatMap f
    where
        fs = concatMap f
        f (Str x) = escape x
        f (TagInline s xs) = "<"++s++">" ++ (if s == "li" then trim else id) (fs xs) ++ "</"++s++">"
        f x = fs $ asInline x

        trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse


showPre :: [Tag] -> [String]
showPre = trimFront . trimLines . lines . concatMap f
    where
        trimLines = dropWhile null . reverse . dropWhile null . reverse
        trimFront xs = map (drop i) xs
            where
                ns = [length a | x <- xs, let (a,b) = span isSpace x, b /= ""]
                i = if null ns then 0 else minimum ns

        fs = concatMap f
        f (Str x) = escape x
        f (TagInline s xs) = "<"++s++">" ++ fs xs ++ "</"++s++">"
        f x = fs $ asInline x


unwordsWrap :: Int -> [String] -> [String]
unwordsWrap n = f n []
    where
        f _ s [] = [g s | s /= []]
        f i s (x:xs) | nx > i = g s : f (n - nx - 1) [x] xs
                     | otherwise = f (i - nx - 1) (x:s) xs
            where nx = length x

        g = unwords . reverse


escape :: String -> String
escape = concatMap f
    where
        f '<' = "&lt;"
        f '>' = "&gt;"
        f '&' = "&amp;"
        f x = [x]


-- | Just like 'vcat' but uses '($+$)' instead of '($$)'.
vcat' :: [SDoc] -> SDoc
vcat' = foldr ($+$) empty
