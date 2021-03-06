{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS -Wall #-}

module Imports (cleanImports) where

import Control.Exception (SomeException)
import Control.Monad (void)
import Control.Monad.Trans (liftIO, MonadIO)
import Data.Char (toLower)
import Data.Foldable (fold)
import Data.Function (on)
import Data.List (find, groupBy, intercalate, nub, sortBy)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Monoid ((<>))
import Data.Sequence ((|>))
import Data.Set as Set (fromList, member, Set, toList, unions)
import qualified Data.Set as Set (map)
import Debug.Trace (trace)
import FoldM (foldDeclsM, foldExportsM, foldHeaderM, foldImportsM)
import qualified Language.Haskell.Exts.Annotated as A (ImportDecl(ImportDecl, importAs, importModule, importQualified, importSpecs), ImportSpec(..), ImportSpecList(..), Module(..), ModuleHead(ModuleHead), ModuleName(ModuleName), SrcLoc(SrcLoc))
import Language.Haskell.Exts.Annotated.Simplify as S (sImportDecl, sImportSpec, sModuleName, sName)
import Language.Haskell.Exts.Extension (Extension(EnableExtension))
import Language.Haskell.Exts.Pretty (defaultMode, PPHsMode(layout), PPLayout(PPInLine), prettyPrintWithMode)
import Language.Haskell.Exts.SrcLoc (SrcSpanInfo)
import qualified Language.Haskell.Exts.Syntax as S (ImportDecl(importLoc, importModule, importSpecs), ModuleName(..), Name(..))
import ModuleKey (ModuleKey(_moduleTop))
import SrcLoc (srcLoc)
import Symbols (symbolsDeclaredBy)
import System.Exit (ExitCode(ExitSuccess, ExitFailure))
import System.FilePath ((</>))
import System.FilePath.Extra2 (replaceFile)
import System.Process (readProcessWithExitCode, showCommandForUser)
import Types (ModuleInfo(ModuleInfo, _module, _moduleKey, _modulePath, _moduleText), DerivDeclTypes(derivDeclTypes), hseExtensions, hsFlags, loadModule)

-- | Run ghc with -ddump-minimal-imports and capture the resulting .imports file.
cleanImports :: MonadIO m => FilePath -> [ModuleInfo] -> m ()
cleanImports scratch [] = trace ("cleanImports - no modules") (pure ())
cleanImports scratch info =
    dump >> mapM_ (\x -> do newText <- doModule scratch x
                            let path = _moduleTop (_moduleKey x) </> _modulePath x
                            liftIO $ case newText of
                                       Nothing -> putStrLn (path ++ ": unable to clean imports")
                                       Just s | _moduleText x /= s ->
                                                        do putStrLn (path ++ " imports changed")
                                                           -- let (path', ext) = splitExtension path in
                                                           -- writeFile {-path' ++ "-new" ++ ext-} s
                                                           void $ replaceFile path s
                                       Just _ -> pure ()) info
    where
      keys = Set.fromList (map _moduleKey info)
      dump = do
        let cmd = "ghc"
            args' = hsFlags ++
                    ["--make", "-c", "-ddump-minimal-imports", "-outputdir", scratch, "-i" ++
                    intercalate ":" (toList (Set.map _moduleTop keys))] ++
                    concatMap ppExtension hseExtensions ++
                    map _modulePath info
        (code, _out, err) <- liftIO $ readProcessWithExitCode cmd args' ""
        case code of
          ExitSuccess -> return ()
          ExitFailure _ -> error ("cleanImports: dump failed\n " ++ showCommandForUser cmd args' ++ " ->\n" ++ err)
      ppExtension (EnableExtension x) = ["-X"++ show x]
      ppExtension _ = []

-- | Parse the import list generated by GHC, parse the original source
-- file, and if all goes well insert the new imports into the old
-- source file.  We also need to modify the imports of any names
-- that are types that appear in standalone instance derivations so
-- their members are imported too.
doModule :: MonadIO m => FilePath -> ModuleInfo -> m (Maybe String)
doModule scratch info@(ModuleInfo {_module = A.Module _ mh _ oldImports _}) =
    do let name = maybe "Main" (\ (A.ModuleHead _ (A.ModuleName _ s) _ _) -> s) mh
       let importsPath = scratch </> name ++ ".imports"

       -- The .imports file will appear in the real current directory,
       -- ignore the source dir path.  This may change in future
       -- versions of GHC, see http://ghc.haskell.org/trac/ghc/ticket/7957
       -- markForDelete importsPath
       liftIO (loadModule importsPath) >>=
              either (\(e :: SomeException) -> error $ "Could not load generated imports: " ++ show e)
                     (\(ModuleInfo {_module = newImports}) ->
                          updateSource True info newImports extraImports)
    where
      extraImports = filter isHiddenImport oldImports
      isHiddenImport (A.ImportDecl {A.importSpecs = Just (A.ImportSpecList _ True _)}) = True
      isHiddenImport _ = False
doModule _ _ = error "Unsupported module type"

-- | If all the parsing went well and the new imports differ from the
-- old, update the source file with the new imports.
updateSource :: MonadIO m => Bool -> ModuleInfo -> A.Module SrcSpanInfo -> [A.ImportDecl SrcSpanInfo] -> m (Maybe String)
updateSource removeEmptyImports info@(ModuleInfo {_module = A.Module _ _ _ oldImports _, _moduleKey = _key}) (A.Module _ _ _ newImports _) extraImports =
    replaceImports (fixNewImports removeEmptyImports info oldImports (newImports ++ extraImports)) info
updateSource _ _ _ _ = error "updateSource"

-- | Compare the old and new import sets and if they differ clip out
-- the imports from the sourceText and insert the new ones.
replaceImports :: MonadIO m => [A.ImportDecl SrcSpanInfo] -> ModuleInfo -> m (Maybe String)
replaceImports newImports info = do
  oldPretty <- fold <$> (foldImportsM (\ _ pref s suff r -> pure $ r |> (pref <> s <> suff)) info mempty)
        -- Surround newPretty with the same prefix and suffix as oldPretty
  importPref <- foldImportsM (\ _ pref _ _ r -> pure $ maybe (Just pref) Just r) info Nothing
  importSuff <- foldImportsM (\ _ _ _ suff _ -> pure suff) info mempty
  let newPretty = fromMaybe "" importPref <>
                  intercalate "\n" (Prelude.map (prettyPrintWithMode (defaultMode {layout = PPInLine})) newImports) <>
                  importSuff
  case oldPretty == newPretty of
    True -> pure Nothing
    False -> do
      h <- foldHeaderM (\ s r -> pure $ r |> s)
                      (\ _ pref s suff r -> pure $ r |> (pref <> s <> suff))
                      (\ _ pref s suff r -> pure $ r |> pref <> s <> suff)
                      (\ _ pref s suff r -> pure $ r |> pref <> s <> suff) info mempty
      e <- foldExportsM (\ s r -> pure $ r |> s)
                       (\ _ pref s suff r -> pure $ r |> pref <> s <> suff)
                       (\ s r -> pure $ r |> s) info mempty
      d <- foldDeclsM  (\ _ pref s suff r -> pure $ r |> pref <> s <> suff)
                      (\ r s -> pure $ s |> r) info mempty
      pure $ Just (fold h ++ fold e ++ newPretty <> fold d)

-- | Final touch-ups - sort and merge similar imports.
fixNewImports :: Bool         -- ^ If true, imports that turn into empty lists will be removed
              -> ModuleInfo
              -> [A.ImportDecl SrcSpanInfo]
              -> [A.ImportDecl SrcSpanInfo]
              -> [A.ImportDecl SrcSpanInfo]
fixNewImports remove m oldImports imports =
    filter importPred $ Prelude.map expandSDTypes $ Prelude.map mergeDecls $ groupBy (\ a b -> importMergable a b == EQ) $ sortBy importMergable imports
    where
      -- mergeDecls :: [ImportDecl] -> ImportDecl
      mergeDecls [] = error "mergeDecls"
      mergeDecls xs@(x : _) = x {A.importSpecs = mergeSpecLists (catMaybes (Prelude.map A.importSpecs xs))}
          where
            -- Merge a list of specs for the same module
            mergeSpecLists :: [A.ImportSpecList SrcSpanInfo] -> Maybe (A.ImportSpecList SrcSpanInfo)
            mergeSpecLists (A.ImportSpecList loc flag specs : ys) =
                Just (A.ImportSpecList loc flag (mergeSpecs (sortBy compareSpecs (nub (concat (specs : Prelude.map (\ (A.ImportSpecList _ _ specs') -> specs') ys))))))
            mergeSpecLists [] = error "mergeSpecLists"
      expandSDTypes :: A.ImportDecl SrcSpanInfo -> A.ImportDecl SrcSpanInfo
      expandSDTypes i@(A.ImportDecl {A.importSpecs = Just (A.ImportSpecList l f specs)}) =
          i {A.importSpecs = Just (A.ImportSpecList l f (Prelude.map (expandSpec i) specs))}
      expandSDTypes i = i
      expandSpec i s =
          if not (A.importQualified i) && member (Nothing, sName n) sdTypes ||
             maybe False (\ mn -> (member (Just (sModuleName mn), sName n) sdTypes)) (A.importAs i) ||
             member (Just (sModuleName (A.importModule i)), sName n) sdTypes
          then s'
          else s
          where
            n = case s of
                  (A.IVar _ x) -> x
                  (A.IAbs _ _ x) -> x
                  (A.IThingAll _ x) -> x
                  (A.IThingWith _ x _) -> x
            s' = case s of
                  (A.IVar l x) -> A.IThingAll l x
                  (A.IAbs l _ x) -> A.IThingAll l x
                  (A.IThingWith l x _) -> A.IThingAll l x
                  (A.IThingAll _ _) -> s

      -- Eliminate imports that became empty
      -- importPred :: ImportDecl -> Bool
      importPred (A.ImportDecl _ mn _ _ _ _ _ (Just (A.ImportSpecList _ _ []))) =
          not remove || maybe False (isEmptyImport . A.importSpecs) (find ((== (sModuleName mn)) . sModuleName . A.importModule) oldImports)
          where
            isEmptyImport (Just (A.ImportSpecList _ _ [])) = True
            isEmptyImport _ = False
      importPred _ = True

      sdTypes :: Set (Maybe S.ModuleName, S.Name)
      sdTypes = standaloneDerivingTypes m

-- | Compare the two import declarations ignoring the things that are
-- actually being imported.  Equality here indicates that the two
-- imports could be merged.
importMergable :: A.ImportDecl SrcSpanInfo -> A.ImportDecl SrcSpanInfo -> Ordering
importMergable a b =
    case (compare `on` noSpecs) a' b' of
      EQ -> EQ
      specOrdering ->
          case (compare `on` S.importModule) a' b' of
            EQ -> specOrdering
            moduleNameOrdering -> moduleNameOrdering
    where
      a' = sImportDecl a
      b' = sImportDecl b
      -- Return a version of an ImportDecl with an empty spec list and no
      -- source locations.  This will distinguish "import Foo as F" from
      -- "import Foo", but will let us group imports that can be merged.
      -- Don't merge hiding imports with regular imports.
      A.SrcLoc path _ _ = srcLoc a
      noSpecs :: S.ImportDecl -> S.ImportDecl
      noSpecs x = x { S.importLoc = A.SrcLoc path 1 1, -- can we just use srcLoc a?
                      S.importSpecs = case S.importSpecs x of
                                        Just (True, _) -> Just (True, []) -- hiding
                                        Just (False, _) -> Nothing
                                        Nothing -> Nothing }

-- Merge elements of a sorted spec list as possible
-- unimplemented, should merge Foo and Foo(..) into Foo(..), and the like
mergeSpecs :: [A.ImportSpec SrcSpanInfo] -> [A.ImportSpec SrcSpanInfo]
mergeSpecs [] = []
mergeSpecs [x] = [x]
{-
-- We need to do this using the simplified syntax
mergeSpecs (x : y : zs) =
    case (name x' == name y', x, y) of
      (True, S.IThingAll _ _, _) -> mergeSpecs (x : zs)
      (True, _, S.IThingAll _ _) -> mergeSpecs (y : zs)
      (True, S.IThingWith _ n xs, S.IThingWith _ ys) -> mergeSpecs (S.IThingWith n (nub (xs ++ ys)))
      (True, S.IThingWith _ _, _) -> mergeSpecs (x' : zs)
      (True, _, S.IThingWith _ _) -> mergeSpecs (y' : zs)
      _ -> x : mergeSpecs (y : zs)
    where
      x' = sImportSpec x
      y' = sImportSpec y
      name (S.IVar n) = n
      name (S.IAbs n) = n
      name (S.IThingAll n) = n
      name (S.IThingWith n _) = n
-}
mergeSpecs xs = xs

-- Compare function used to sort the symbols within an import.
compareSpecs :: A.ImportSpec SrcSpanInfo -> A.ImportSpec SrcSpanInfo -> Ordering
compareSpecs a b =
    case compare (Set.map (Prelude.map toLower . nameString) $ Set.fromList $ symbolsDeclaredBy a)
                 (Set.map (Prelude.map toLower . nameString) $ Set.fromList $ symbolsDeclaredBy b) of
      EQ -> compare (sImportSpec a) (sImportSpec b)
      x -> x

standaloneDerivingTypes :: ModuleInfo -> Set (Maybe S.ModuleName, S.Name)
standaloneDerivingTypes (ModuleInfo {_module = A.XmlPage _ _ _ _ _ _ _}) = error "standaloneDerivingTypes A.XmlPage"
standaloneDerivingTypes (ModuleInfo {_module = A.XmlHybrid _ _ _ _ _ _ _ _ _}) = error "standaloneDerivingTypes A.XmlHybrid"
standaloneDerivingTypes (ModuleInfo {_module = A.Module _ _ _ _ decls}) =
    unions (Prelude.map derivDeclTypes decls)

nameString :: S.Name -> String
nameString (S.Ident s) = s
nameString (S.Symbol s) = s
