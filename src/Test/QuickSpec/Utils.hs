-- | Miscellaneous utility functions.

module Test.QuickSpec.Utils where

import Control.Arrow((&&&))
import Data.List(groupBy, sortBy, group, sort)
import Data.Ord(comparing)
import System.IO
import Control.Exception
import Control.Spoon

repeatM :: Monad m => m a -> m [a]
repeatM = sequence . repeat

partitionBy :: Ord b => (a -> b) -> [a] -> [[a]]
partitionBy value = groupBy (\x y -> value x == value y) .
                     sortBy (\x y -> compare (value x) (value y))

isSorted :: Ord a => [a] -> Bool
isSorted xs = and (zipWith (<=) xs (tail xs))

isSortedBy :: Ord b => (a -> b) -> [a] -> Bool
isSortedBy f xs = isSorted (map f xs)

usort :: Ord a => [a] -> [a]
usort = map head . group . sort

merge :: Ord b => (a -> a -> a) -> (a -> b) -> [a] -> [a] -> [a]
merge f c = aux
  where aux [] ys = ys
        aux xs [] = xs
        aux (x:xs) (y:ys) =
          case comparing c x y of
            LT -> x:aux xs (y:ys)
            GT -> y:aux (x:xs) ys
            EQ -> f x y:aux xs ys

orElse :: Ordering -> Ordering -> Ordering
EQ `orElse` x = x
x `orElse` _ = x

unbuffered :: IO a -> IO a
unbuffered x = do
  buf <- hGetBuffering stdout
  bracket_
    (hSetBuffering stdout NoBuffering)
    (hSetBuffering stdout buf)
    x

spoony :: Eq a => a -> Maybe a
spoony x = teaspoon ((x == x) `seq` x)
