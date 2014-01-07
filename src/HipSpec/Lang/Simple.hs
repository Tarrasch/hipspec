{-# LANGUAGE DeriveFunctor, DeriveFoldable, DeriveTraversable, TemplateHaskell, ScopedTypeVariables, ViewPatterns #-}
-- | The Simple expression language, a subset of GHC Core
--
-- It is Simple because it lacks lambdas, let and only allows a cascade of
-- cases at the top level.
--
-- There is some code duplication between this and the Rich
-- language. It is unclear how this could be remedied.
module HipSpec.Lang.Simple
    ( Function(..)
    , Body(..)
    , Alt
    , Expr(..)
    , collectArgs
    , apply
    , bodyType
    , exprType
    , exprTySubst
    , module HipSpec.Lang.Rich
    , module HipSpec.Lang.Type
    , injectFn
    , injectBody
    , injectExpr
    , (//)
    , substMany
    , fnIds
    , fnTys
    , fnTyCons
    , tcIds
    , tcTys
    , tcTyCons
    , tyTyCons
    ) where

import Data.Foldable (Foldable)
import Data.Traversable (Traversable)
import Data.Generics.Geniplate

-- Patterns are resued from the rich language
import HipSpec.Lang.Rich (Pattern(..),anyRhs,Datatype(..),Constructor(..))
import qualified HipSpec.Lang.Rich as R
import HipSpec.Lang.Type

{-# ANN module "HLint: ignore Use camelCase" #-}

-- | Function definition,
--   There are no lambdas so the arguments to the functions are
--   declared here.
data Function a = Function
    { fn_name    :: a
    , fn_type    :: PolyType a
    , fn_args    :: [a]
    , fn_body    :: Body a
    }
  deriving (Eq,Ord,Show,Functor,Foldable,Traversable)

-- | The body of a function: cascades of cases, with branches eventually ending
--   in expressions.
data Body a
    = Case (Expr a) [Alt a]
    | Body (Expr a)
  deriving (Eq,Ord,Show,Functor,Foldable,Traversable)

type Alt a = (Pattern a,Body a)

-- | The simple expressions allowed here
data Expr a
    = Lcl a (Type a)
    -- ^ Local variables
    | Gbl a (PolyType a) [Type a]
    -- ^ Global variables applied to their type arguments
    | App (Expr a) (Expr a)
    | Lit Integer
  deriving (Eq,Ord,Show,Functor,Foldable,Traversable)

collectArgs :: Expr a -> (Expr a,[Expr a])
collectArgs (App e1 e2) =
    let (e,es) = collectArgs e1
    in  (e,es ++ [e2])
collectArgs e           = (e,[])

apply :: Expr a -> [Expr a] -> Expr a
apply = foldl App

bodyType :: Eq a => Body a -> Type a
bodyType = R.exprType . injectBody

exprType :: Eq a => Expr a -> Type a
exprType = R.exprType . injectExpr

exprTySubst :: forall a . Eq a => a -> Type a -> Expr a -> Expr a
exprTySubst x t = ex_ty $ \ t0 -> case t0 of
    TyVar y | x == y -> t
    _                -> t0
  where
    ex_ty :: (Type a -> Type a) -> Expr a -> Expr a
    ex_ty = $(genTransformBi 'ex_ty)

(//) :: Eq a => Expr a -> a -> Expr a -> Expr a
e // x = tr_expr $ \ e0 -> case e0 of
    Lcl y _ | x == y -> e
    _                -> e0
  where
    tr_expr :: (Expr a -> Expr a) -> Expr a -> Expr a
    tr_expr = $(genTransformBi 'tr_expr)

substMany :: Eq a => [(a,Expr a)] -> Expr a -> Expr a
substMany xs e0 = foldr (\ (u,e) -> (e // u)) e0 xs

-- * Injectors to the Rich language (for pretty-printing, linting)

injectFn :: Function a -> R.Function a
injectFn (Function f ty as b)
    = R.Function f ty (R.makeLambda (zip as as_ty) (injectBody b))
  where
    Forall _ (collectArrTy -> (as_ty,_)) = ty

injectBody :: Body a -> R.Expr a
injectBody b0 = case b0 of
    Case e alts -> R.Case (injectExpr e) Nothing
                          [ (p,injectBody b) | (p,b) <- alts ]
    Body e      -> injectExpr e

injectExpr :: Expr a -> R.Expr a
injectExpr e0 = case e0 of
    Lcl x t    -> R.Lcl x (Forall [] t) []
    Gbl x t ts -> R.Gbl x t ts
    App e1 e2  -> R.App (injectExpr e1) (injectExpr e2)
    Lit l      -> R.Lit l

fnIds :: Function a -> [a]
fnIds = $(genUniverseBi 'fnIds)

fnTys :: Function a -> [Type a]
fnTys = $(genUniverseBi 'fnTys)

tcIds :: Datatype a -> [a]
tcIds = $(genUniverseBi 'tcIds)

tcTys :: Datatype a -> [Type a]
tcTys = $(genUniverseBi 'tcTys)

tyTys :: Type a -> [Type a]
tyTys = $(genUniverseBi 'tyTys)

tyTyCons :: Type a -> [(a,[Type a])]
tyTyCons t0 = [ (tc,ts) | TyCon tc ts <- tyTys t0 ]

fnTyCons :: Function a -> [(a,[Type a])]
fnTyCons = concatMap tyTyCons . fnTys

tcTyCons :: Datatype a -> [(a,[Type a])]
tcTyCons = concatMap tyTyCons . tcTys

