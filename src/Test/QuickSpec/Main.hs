-- | The main implementation of QuickSpec.

{-# LANGUAGE CPP, TypeOperators, PartialTypeSignatures #-}
module Test.QuickSpec.Main where

#include "errors.h"

import Data.Typeable
import Test.QuickSpec.Generate
import Test.QuickSpec.Reasoning.NaiveEquationalReasoning hiding (universe, maxDepth)
import Test.QuickSpec.Utils.Typed
import qualified Test.QuickSpec.Utils.TypeMap as TypeMap
import qualified Test.QuickSpec.Utils.TypeRel as TypeRel
import Test.QuickSpec.Signature hiding (vars)
import Test.QuickSpec.Term hiding (symbols)
import Control.Monad
import Text.Printf
import Data.Monoid
import Test.QuickSpec.TestTree(TestResults, classes, reps)
import Data.List
import System.Random
import Data.Monoid
import Data.Maybe
import Test.QuickSpec.Utils
import Test.QuickSpec.Equation

undefinedsSig :: Sig -> Sig
undefinedsSig sig =
  background
    [ undefinedSig "undefined" (undefined `asTypeOf` witness x)
    | Some x <- saturatedTypes sig ]

universe :: [[Tagged Term]] -> [Tagged Term]
universe css = filter (not . isUndefined . erase) (concat css)

prune :: Context -> [Term] -> (a -> Equation) -> [a] -> [a]
prune ctx reps erase eqs = evalEQ ctx (filterM (fmap not . provable . erase) eqs)
  where
    provable (t :=: u) = do
      res <- t =?= u
      if res then return True else do
        state <- get
        -- Check that we won't unify two representatives---if we do
        -- the equation is false
        t =:= u
        reps' <- mapM rep reps
        if sort reps' == usort reps' then return False else do
          put state
          return True

defines :: Equation -> Maybe Symbol
defines (t :=: u) = do
  let isVar Var{} = True
      isVar _ = False

      acyclic t =
        all acyclic (args t) &&
        case functor t == functor u of
          True -> usort (map Var (vars t)) `isProperSubsetOf` args u
          False -> True
      xs `isProperSubsetOf` ys = xs `isSubsetOf` ys && sort xs /= sort ys
      xs `isSubsetOf` ys = sort xs `isSublistOf` sort ys
      [] `isSublistOf` _ = True
      (x:xs) `isSublistOf` [] = False
      (x:xs) `isSublistOf` (y:ys)
        | x == y = xs `isSublistOf` ys
        | otherwise = (x:xs) `isSublistOf` ys

  guard (all isVar (args u) && usort (args u) == args u &&
         acyclic t && vars t `isSubsetOf` vars u)

  return (functor u)

definitions :: [Equation] -> [Equation]
definitions es = [ e | e <- es, defines e /= Nothing ]

runTool :: Signature a => (Sig -> IO ()) -> a -> IO ()
runTool tool sig_ = do
  putStrLn "== API =="
  putStr (show (signature sig_))
  let sig = signature sig_ `mappend` undefinedsSig (signature sig_)

  tool sig

data Target = Target Symbol | NoTarget deriving (Eq, Ord)

target :: Equation -> Target
target (t :=: u) =
  case usort (filter p (funs t ++ funs u)) of
    [f] -> Target f
    _ -> NoTarget
  where p x = not (silent x) && symbolArity x > 0

innerZip :: [a] -> [[b]] -> [[(a,b)]]
innerZip [] _ = []
innerZip _ [] = []
innerZip xs ([]:yss) = []:innerZip xs yss
innerZip (x:xs) ((y:ys):yss) =
  let (zs:zss) = innerZip xs (ys:yss)
  in ((x,y):zs):zss

-- | Run QuickSpec on a signature.
quickSpec :: Signature a => a -> IO ()
quickSpec = runTool $ \sig -> do
  putStrLn "== Testing =="
  rs <- genRs sig
  let clss = getClasses rs
      univ = concatMap (some2 (map (tagged term))) clss
      reps = map (some2 (tagged term . head)) clss
      eqs = equations clss
  printf "%d raw equations; %d terms in universe.\n\n"
    (length eqs)
    (length reps)

  let ctx = initial (maxDepth sig) (symbols sig) univ
      allEqs = map (some eraseEquation) eqs
      isBackground = all silent . eqnFuns
      keep eq = not (isBackground eq) || absurd eq
      absurd (t :=: u) = absurd1 t u || absurd1 u t
      absurd1 (Var x) t = x `notElem` vars t
      absurd1 _ _ = False
      (background, foreground) =
        partition isBackground allEqs
      pruned = filter keep
                 (prune ctx (filter (not . isUndefined) (map erase reps)) id
                   (background ++ foreground))
      eqnFuns (t :=: u) = funs t ++ funs u
      isGround (t :=: u) = null (vars t) && null (vars u)
      byTarget = innerZip [1 :: Int ..] (partitionBy target pruned)

  forM_ byTarget $ \eqs@((_,eq):_) -> do
    case target eq of
      NoTarget -> putStrLn "== Equations about several functions =="
      Target f -> printf "== Equations about %s ==\n" (show f)
    forM_ eqs $ \(i, eq) ->
      printf "%3d: %s\n" i (showEquation sig eq)
    putStrLn ""

quickSpec2 :: Signature a => a -> IO ()
quickSpec2 = runTool $ \sig -> do
  rs <- genRs sig
  let clss = getClasses rs
      pruned = prune (initial (maxDepth sig) (symbols sig) (mkUniv clss))
                     (filter (not . isUndefined) (map getRep clss))
                     id
                     (sort (mkEqs clss))
  print pruned

doPrune :: Typeable a => Sig -> [[Expr a]] -> [Equation]
doPrune sig clss = prune (initial (maxDepth sig) (symbols sig) (mkUniv2 clss))
                         (filter (not . isUndefined) (map (term . head) clss))
                         id
                         (sort (mkEqs2 clss))

getRep :: Some (O [] Expr) -> Term
getRep (Some (O x)) = term (head x)

mkEqs2 ((z:zs) : cs) = [term y :=: term z | y <- zs] ++ mkEqs2 cs

mkEqs (Some (O (z:zs)) : cs) = [term y :=: term z | y <- zs] ++ mkEqs cs

mkUniv []     = []
mkUniv (Some (O x):cs) = map univ2 x ++ mkUniv cs

mkUniv2 []     = []
mkUniv2 (x:cs) = map univ2 x ++ mkUniv2 cs

univ2 :: Typeable a => Expr a -> Tagged Term
univ2 y = Tagged (Some (Witness (strip y))) (term y)

strip :: Typeable a => f a -> a
strip x = undefined

getClasses :: [Some (O TestResults Expr)] -> [Some (O [] Expr)]
getClasses = concatMap (some2 mapForClasses)

getClasses2 :: Typeable a => [[Expr a]]
getClasses2 = undefined

mapForClasses :: (Ord (g a), Typeable a) => TestResults (g a) -> [Some (O [] g)]
mapForClasses = map (Some . O) . classes

genR :: Sig -> IO (TypeMap.TypeMap (O TestResults Expr))
genR = generate False (const partialGen)

genRs :: Sig -> IO [Some (O TestResults Expr)]
genRs sig = TypeMap.toList <$> genR sig

sampleList :: StdGen -> Int -> [a] -> [a]
sampleList g n xs | n >= length xs = xs
                  | otherwise = aux g n (length xs) xs
  where
    aux g 0 _ _ = []
    aux g _ _ [] = ERROR "sampleList: bug in sampling"
    aux g size len (x:xs)
      | i <= size = x:aux g' (size-1) (len-1) xs
      | otherwise = aux g' size (len-1) xs
      where (i, g') = randomR (1, len) g

-- | Generate random terms from a signature. Useful when QuickSpec is
--   generating too many terms and you want to know what they look like.
sampleTerms :: Signature a => a -> IO ()
sampleTerms = runTool $ \sig -> do
  putStrLn "== Testing =="
  r <- generate False (const partialGen) (updateDepth (maxDepth sig - 1) sig)
  let univ = sort . concatMap (some2 (map term)) . TypeMap.toList . terms sig .
             TypeMap.mapValues2 reps $ r
  printf "Universe contains %d terms.\n\n" (length univ)

  let numTerms = 100

  printf "== Here are %d terms out of a total of %d ==\n" numTerms (length univ)
  g <- newStdGen
  forM_ (zip [1 :: Int ..] (sampleList g numTerms univ)) $ \(i, t) ->
    printf "%d: %s\n" i (show (mapVars (disambiguate sig (vars t)) t))

  putStrLn ""
