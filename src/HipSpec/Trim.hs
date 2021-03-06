{-# LANGUAGE NamedFieldPuns,ScopedTypeVariables #-}
{-

   Trims away unnecessary function definitions from a grand theory.

-}
module HipSpec.Trim where

import HipSpec.Theory

import Data.Maybe
import Data.Graph
import Data.Tree

import Data.List

-- | Trim down a grand theory, from the recursive dependencies from a set
--   of interesting subtheories.
--
--   We make a graph. Every recursive group defines some content fs
--   and depends on some content ds. Make an arrow from fs to each ds.
--   In the end, we follow all arrows from our initial important
--   subtheory.
--
--   We have keys as Content, and nodes are their corresponding Subtheories.
--
--   You can memo-thunk this function with the same grand_theory.
trim :: [Subtheory] -> [Content] -> [Subtheory]
trim grand_theory =
    let gr :: [(Subtheory,Content,[Content])]
        gr = [ (subthy,defines subthy,dependencies subthy)
             | subthy <- grand_theory
             ]

        g          :: Graph
        fromVertex :: Vertex -> (Subtheory,Content,[Content])
        toVertex   :: Content -> Maybe Vertex
        (g,fromVertex,toVertex) = graphFromEdges gr

        get_subtheory :: (Subtheory,Content,[Content]) -> Subtheory
        get_subtheory (s,_,_) = s

    in  \ important ->
            let err :: Content -> Vertex
                err content = error $ "HipSpec.Trim.trim: Trying to find dependencies of "
                                    ++ show content ++ " which could not be found, when searching for:\n"
                                    ++ intercalate "," (map show important)
                                    ++ "\nWhole theory defines:\n"
                                    ++ intercalate "," (map (show . defines) grand_theory)

                findVertex :: Content -> Vertex
                findVertex v = fromMaybe (err v) (toVertex v)

                forest :: Forest Vertex
                forest = dfs g (map findVertex important)

            in  map (get_subtheory . fromVertex) (concatMap flatten forest)

