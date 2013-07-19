-- | Gets the GHC Core information we need, also sets up the system for later
--   QuickSpec execution
{-# LANGUAGE RecordWildCards #-}
module HipSpec.Read (execute,EntryResult(..),SigInfo(..)) where

import HipSpec.ParseDSL

import Data.List.Split (splitOn)

import HipSpec.Sig.Map
import HipSpec.Sig.Make
import HipSpec.Sig.Get

import HipSpec.Params

-- import CoreMonad (liftIO)
import DynFlags
import GHC hiding (Sig)
import GHC.Paths
import HscTypes
import StaticFlags

import Var

import HipSpec.GHC.Unfoldings
import HipSpec.GHC.Utils

import qualified Data.Map as M
import Data.Map (Map)

import Data.Maybe
import Data.List

import TysWiredIn
import DataCon (dataConName)
import TyCon (TyCon,tyConName)
import BasicTypes (TupleSort(BoxedTuple))

import Control.Monad

-- | The result from calling GHC
data EntryResult = EntryResult
    { sig_info  :: Maybe SigInfo
    , prop_ids  :: [Var]
    , extra_tcs :: [TyCon]
    }

execute :: Params  -> IO EntryResult
execute params@Params{..} = do

    -- Use -threaded
    addWay WayThreaded

    -- Notify where ghc is installed
    runGhc (Just libdir) $ do

        -- Set interpreted so we can get the signature,
        -- and expose all unfoldings
        dflags0 <- getSessionDynFlags
        let dflags = dflags0 { ghcMode = CompManager
                             , optLevel = 1
                             , profAuto = NoProfAuto
                             }
                `dopt_unset` Opt_IgnoreInterfacePragmas
                `dopt_unset` Opt_OmitInterfacePragmas
                `dopt_set` Opt_ExposeAllUnfoldings
        _ <- setSessionDynFlags dflags

        -- Try to get the target
        let file' | ".hs" `isSuffixOf` file = take (length file - 3) file
                  | otherwise               = file

        target <- guessTarget (file' ++ ".hs") Nothing
        _ <- addTarget target
        r <- load LoadAllTargets
        when (failed r) $ error "Compilation failed!"

        mod_graph <- getModuleGraph
        let mod_sum = fromMaybe (error $ "Cannot find module " ++ file')
                    $ find (\m -> ms_mod_name m == mkModuleName file'
                               || ms_mod_name m == mkModuleName (replace '/' '.' file')
                               || ms_mod_name m == mkModuleName "Main"
                               || ml_hs_file (ms_location m) == Just file')
                           mod_graph
              where replace a b xs = map (\ x -> if x == a then b else x) xs

        -- Parse, typecheck and desugar the module
        p <- parseModule mod_sum
        t <- typecheckModule p
        d <- desugarModule t

        let modguts = dm_core_module d

            binds = fixUnfoldings (mg_binds modguts)

            fix_id :: Id -> Id
            fix_id = fixId binds

        -- Set the context for evaluation
        setContext $
            [ IIDecl (simpleImportDecl (moduleName (ms_mod mod_sum)))
            , IIDecl (qualifiedImportDecl (mkModuleName "Test.QuickSpec.Signature"))
            , IIDecl (qualifiedImportDecl (mkModuleName "Test.QuickSpec.Prelude"))
            , IIDecl (qualifiedImportDecl (mkModuleName "GHC.Types"))
            , IIDecl (qualifiedImportDecl (mkModuleName "Prelude"))
            ]
            -- Also include the imports the module is importing
            ++ map (IIDecl . unLoc) (ms_textual_imps mod_sum)

        -- Get everything in scope
        named_things <- getNamedThings fix_id

        let only' :: [String]
            only' = concatMap (splitOn ",") only

            props :: [Var]
            props =
                [ i
                | (_,AnId i) <- M.toList named_things
                , varWithPropType i
                , null only' || varToString i `elem` only'
                ]

        -- Make or get signature
        m_sig <- if auto
            then makeSignature params named_things props
            else getSignature (map fst $ M.toList named_things)

        -- Make signature map
        sig_info <- case m_sig of
            Nothing -> return Nothing
            Just sig -> do
                sig_map <- makeSigMap params sig named_things
                return $ Just SigInfo
                    { sig     = sig
                    , sig_map = sig_map
                    }

        -- Wrapping up
        return EntryResult
            { sig_info  = sig_info
            , prop_ids  = props ++ case sig_info of
                Just (SigInfo _ (SigMap m _)) -> M.elems m
                Nothing                       -> []
            , extra_tcs = case sig_info of
                Just (SigInfo _ (SigMap _ m)) -> M.elems m
                Nothing                       -> []
            }

qualifiedImportDecl :: ModuleName -> ImportDecl name
qualifiedImportDecl m = (simpleImportDecl m) { ideclQualified = True }

-- | Getting the names in scope
--
--   Context for evaluation needs to be set before
getNamedThings :: (Id -> Id) -> Ghc (Map Name TyThing)
getNamedThings fix_id = do

    -- Looks up a name and tries to associate it with a typed thing
    let lookup_name :: Name -> Ghc (Maybe (Name,TyThing))
        lookup_name n = fmap (fmap (\ (tyth,_,_) -> (n,tyth))) (getInfo n)

    -- Get the types of all names in scope
    ns <- getNamesInScope

    maybe_named_things <- mapM lookup_name ns

    return $ M.fromList $
        [ (n,mapTyThingId fix_id tyth)
        | Just (n,tyth) <- maybe_named_things
        ] ++
        -- These built in constructors are not in scope by default (!?), so we add them here
        -- Note that tuples up to size 8 are only supported...
        concat
            [ (tyConName tc,ATyCon tc) :
              [ (dataConName dc,ADataCon dc) | dc <- tyConDataCons tc ]
            | tc <- [listTyCon,unitTyCon,pairTyCon] ++ map (tupleTyCon BoxedTuple) [3..8]
            ]

mapTyThingId :: (Id -> Id) -> TyThing -> TyThing
mapTyThingId k (AnId i) = AnId (k i)
mapTyThingId _ tyth     = tyth
