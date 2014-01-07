{-# LANGUAGE ScopedTypeVariables,DeriveFunctor,FlexibleInstances,MultiParamTypeClasses #-}
-- | Translating the rich language to the simple language
--
-- Lambdas, lets an inner cases are lifted to the top level.
--
-- Free vars is calculated relative to the bound variables to not have to be
-- able to keep track of all top-level bound identifiers.
--
--   f = \ x -> g x
--
-- In the expression (g x) in this context, only x is free.
--
module HipSpec.Lang.RichToSimple where

import HipSpec.Lang.Rich as R
import HipSpec.Lang.Simple as S

import HipSpec.Lang.SimplifyRich (removeScrutinee)

import HipSpec.Lang.Scope

import Control.Monad.RWS
import Control.Applicative

import Data.List (nub,(\\))

newtype Env v = Env (Scope v,[Loc v])

instance HasScope v (Env v) where
    get_scope (Env (s,_))   = get_scope s
    mod_scope f (Env (s,a)) = Env (mod_scope f s,a)

type RTS = RWS
    (Env Id)        -- variables in scope
    [S.Function Id] -- emitted lifted functions
    Integer              -- name supply

emit :: S.Function Id -> RTS ()
emit = tell . (:[])

runRTS :: Ord v => RTS a -> (a,[S.Function Id])
runRTS = runRTSWithScope [] []

runRTSWithScope :: Ord v =>
    [Loc (Rename v)] -> [Id] -> RTS a -> (a,[S.Function Id])
runRTSWithScope loc sc m = evalRWS m (Env (makeScope sc,map star loc)) 0

getLocs :: RTS [Loc (Rename v)]
getLocs = do
    Env (_,ls) <- ask
    let ls' :: [Loc (Rename v)]
        ls' = [ forget l | l <- ls ]
    return ls'

withNewLoc :: Loc (Rename v) -> RTS a -> RTS a
withNewLoc l = local $ \ (Env (sc,ls)) -> Env (sc,ls ++ [star l])

fresh :: Type (Rename v) -> RTS Id
fresh t = do
    ls <- getLocs
    state $ \ s -> (New ls s ::: t,succ s)

rtsFun :: Ord v => R.Function Id -> RTS (S.Function Id)
rtsFun (R.Function f tvs e) = do
    let (args,body) = collectBinders e
    withNewLoc (LetLoc (forget_type f)) $ clearScope $ extendScope args $
        S.Function f tvs args <$> rtsBody body

rtsBody :: Ord v => R.Expr Id -> RTS (S.Body Id)
rtsBody e0 = case e0 of
    R.Case e x alts -> S.Case <$> rtsExpr e <*> sequence
        [ (,) p <$> bindPattern p (rtsBody (removeScrutinee e x alt))
        | alt@(p,_) <- alts
        ]
    _ -> S.Body <$> rtsExpr e0
  where
    bindPattern p = case p of
        ConPat _ _ bs -> extendScope bs
        _             -> id

rtsExpr :: R.Expr Id -> RTS (S.Expr Id)
rtsExpr e0 = case e0 of
    R.Var x ts  -> return (S.Var x ts)
    R.App e1 e2 -> S.App <$> rtsExpr e1 <*> rtsExpr e2
    R.Lit l t   -> return (S.Lit l t)
    R.String{}  -> error "rtsExpr: Strings are not supported!"

    -- Lambda-lifting of lambda as case
    -- Emits a new function, and replaces the body with this new function
    -- applied to the type variables and free variables.
    R.Lam{}  -> emitFun LamLoc e0
    R.Case{} -> emitFun CaseLoc e0

    R.Let fns e -> do
        -- See Example tricky let lifting

        let binders = map R.fn_name fns
            free_vars_overapprox
                = nub (concatMap (R.freeVars . R.fn_body) fns) \\ binders

        free_vars <- freeVarsOf free_vars_overapprox

        let handle_fun (R.Function fn@(f ::: ft) _ body) = withNewLoc (LetLoc f) $ do

                f' <- fresh new_type

                -- TODO: Change to substLcl instead of tySubst... The
                --  variable should be replaced with a Gbl instead of Lcl
                --  too
                let subst = tySubst fn $ \ ty_args ->
                        R.Var f' (map (star . TyVar) new_ty_vars ++ ty_args)
                        `R.apply`
                        map (`R.Var` []) free_vars

                    fn' = R.Function f' (star (new_ty_vars ++ tvs)) new_lambda

                return (subst,fn')
              where
                (tvs,_) = collectForalls ft

                new_lambda = makeLambda free_vars body

                new_type_body = R.exprType new_lambda

                new_ty_vars = freeTyVars new_type_body \\ tvs

                new_type = makeForalls (new_ty_vars ++ tvs) new_type_body

        (substs,fns') <- mapAndUnzipM handle_fun fns

        -- Substitutions of the functions applied to their new arguments
        let subst :: R.Expr Id -> R.Expr Id
            subst = foldr (.) id substs

        tell =<< mapM (rtsFun . mapFnBody subst) fns'

        rtsExpr (subst e)

{-

Example tricky let lifting:

    f :: forall a . a -> ([a],[a])
    f =
      \ (x :: a) ->
        let {
          g :: forall b . b -> [a]
          g = \ (y :: b) -> [] @ a
        } in (,) @ [a] @ [a]
                (g @ a x)
                (g @ [Bool] (: @ Bool True ([] @ Bool)))

This should be lifted to:

    g :: forall a b . b -> [a]
    g = \ (y :: b) -> [] @ a

    f :: forall a . a -> ([a],[a])
    f =
      \ (x :: a) ->
        (,) @ [a] @ [a]
           (g @ a @ a x)
           (g @ a @ [Bool] (: @ Bool True ([] @ Bool)))

-}

emitFun :: Loc (Rename v) -> R.Expr Id -> RTS (S.Expr Id)
emitFun l body = do

    args <- exprFreeVars body

    let new_lambda = makeLambda args body

        new_type   = R.exprType new_lambda

        ty_vars    = freeTyVars new_type

    withNewLoc l $ do

        f <- fresh (makeForalls ty_vars new_type)

        emit =<< rtsFun (R.Function f (star ty_vars) new_lambda)

        return (S.apply (S.Var f (map (star . S.TyVar) ty_vars))
                        (map (`S.Var` []) args))

-- | Gets the free vars of an expression
exprFreeVars :: Ord v => R.Expr Id -> RTS [Id]
exprFreeVars = freeVarsOf . R.freeVars

-- | Given a list of variables, gets the free variables and their types
freeVarsOf :: Ord v => [Id] -> RTS [Id]
freeVarsOf = pluckScoped

typeVarsOf :: Ord v => Type Id -> [Id]
typeVarsOf = nub . freeTyVars

