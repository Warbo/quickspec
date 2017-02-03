-- | The testing loop and term generation of QuickSpec.

{-# LANGUAGE CPP, Rank2Types, TypeOperators, ScopedTypeVariables, BangPatterns #-}
module Test.QuickSpec.Generate where

#include "errors.h"
import Test.QuickSpec.Signature hiding (con)
import qualified Test.QuickSpec.TestTree as T
import Test.QuickSpec.TestTree(TestResults, reps, classes, numTests, numResults, cutOff, discrete)
import Test.QuickSpec.Utils.Typed
import Test.QuickSpec.Utils.TypeRel(TypeRel)
import qualified Test.QuickSpec.Utils.TypeRel as TypeRel
import Test.QuickSpec.Utils.TypeMap(TypeMap)
import qualified Test.QuickSpec.Utils.TypeMap as TypeMap
import Test.QuickSpec.Term
import Text.Printf
import Test.QuickSpec.Utils.Typeable
import Test.QuickSpec.Utils
import Test.QuickCheck.Gen hiding (generate)
import Test.QuickCheck.Random
import System.Random
import Control.Spoon
import Test.QuickSpec.Utils.MemoValuation

terms :: Sig -> TypeRel Expr -> TypeRel Expr
terms = termsSatisfying (const True)

termsSatisfying :: (Term -> Bool) -> Sig -> TypeRel Expr -> TypeRel Expr
termsSatisfying p sig base =
  TypeMap.fromList
    [ Some (O (terms' p sig base w))
    | Some (Witness w) <- usort (saturatedTypes sig ++ variableTypes sig) ]

terms' :: Typeable a => (Term -> Bool) -> Sig -> TypeRel Expr -> a -> [Expr a]
terms' p sig base w = filter check (go w)
  where go :: Typeable b => b -> [Expr b]
        go w = map var (TypeRel.lookup w (variables sig)) ++
               map con (TypeRel.lookup w (constants sig)) ++
               [ app f x
               | Some (Witness w') <- lhsWitnesses sig w,
                 x <- onlyTerms (TypeRel.lookup w' base),
                 f <- unshare (Just x) (onlyTerms (filter ((> 0) . arity) (go (const w))))]

        check t   = size 1 (term t) <= maxSize sig && p (term t)
        onlyTerms = filter (not . isUndefined . term)

        getXs :: (Typeable x) => x -> [Expr x]
        getXs w'  = onlyTerms (TypeRel.lookup w' base)

        getX n w' = getXs w' !! n

        getFs :: (Typeable x, Typeable y) => (x -> y) -> [Expr (x -> y)]
        getFs fw  = onlyTerms (filter ((> 0) . arity) (go fw))

        getF n fw = getFs fw !! n

        unshare x y = x `seq` y

        indices :: x -> [Expr x] -> [Int]
        indices _ [] = []
        indices _ xs = let n = length xs - 1
                         in n `seq` [0..n]

test :: [(Valuation, QCGen, Int)] -> Sig ->
        TypeMap (List `O` Expr) -> TypeMap (TestResults `O` Expr)
test vals sig ts = fmap (mapSome2 (test' vals sig)) ts

test' :: forall a. Typeable a =>
         [(Valuation, QCGen, Int)] -> Sig -> [Expr a] -> TestResults (Expr a)
test' vals sig ts
  | not (testable sig (undefined :: a)) = discrete ts
  | otherwise =
    case observe undefined sig of
      Observer obs ->
        let testCase (val, g, n) x =
              spoony . unGen (partialGen obs) g n $ eval x val
        in cutOff base increment (T.test (map testCase vals) ts)
  where
    base = minTests sig `div` 2
    increment = minTests sig - base

genSeeds :: Int -> IO [(QCGen, Int)]
genSeeds maxSize = do
  rnd <- newQCGen
  let rnds rnd = rnd1 : rnds rnd2 where (rnd1, rnd2) = split rnd
  return (zip (rnds rnd) (concat (repeat [0,2..maxSize])))

toValuation :: Strategy -> Sig -> (QCGen, Int) -> (Valuation, QCGen, Int)
toValuation strat sig (g, n) =
  let (g1, g2) = split g
  in (memoValuation sig (unGen (valuation strat) g1 n), g2, n)

generate :: Bool -> Strategy -> Sig -> IO (TypeMap (TestResults `O` Expr))
generate shutUp strat sig = generateTermsSatisfying shutUp (const True) strat sig

generateTermsSatisfying :: Bool -> (Term -> Bool) -> Strategy -> Sig -> IO (TypeMap (TestResults `O` Expr))
generateTermsSatisfying shutUp p strat sig | maxDepth sig < 0 =
  ERROR "generate: maxDepth must be positive"
generateTermsSatisfying shutUp p strat sig | maxDepth sig == 0 = return TypeMap.empty
generateTermsSatisfying shutUp p strat sig = unbuffered $ do
  let d = maxDepth sig
      quietly x | shutUp = return ()
                | otherwise = x
  rs <- fmap (TypeMap.mapValues2 reps) (generate shutUp (const partialGen) (updateDepth (d-1) sig))
  quietly $ printf "Depth %d: " d
  let count :: ([a] -> a) -> (forall b. f (g b) -> a) ->
               TypeMap (f `O` g) -> a
      count op f = op . map (some2 f) . TypeMap.toList
      ts = termsSatisfying p sig rs
  --quietly $ printf "%d terms, " (count sum length ts)
  seeds <- genSeeds (maxQuickCheckSize sig)
  let p (val, _, _) = condition sig sig val
      tests = if length ps < 10
                 then Nothing
                 else Just (ps ++ qs)
        where
          (ys, zs) = splitAt 1000 (map (toValuation strat sig) seeds)
          ps = filter p ys
          qs = filter p zs
  case tests of
    Nothing -> return TypeMap.empty
    Just tests -> do
      return (test tests sig ts)
      {-quietly $
        printf "%d tests, %d evaluations, %d classes, %d raw equations.\n"
          (count (maximum . (0:)) numTests cs)
          (count sum numResults cs)
          (count sum (length . classes) cs)
          (count sum (sum . map (subtract 1 . length) . classes) cs)-}

eraseClasses :: TypeMap (TestResults `O` Expr) -> [[Tagged Term]]
eraseClasses = concatMap (some (map (map (tagged term)) . classes . unO)) . TypeMap.toList
