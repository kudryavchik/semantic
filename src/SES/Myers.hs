{-# LANGUAGE GADTs, MultiParamTypeClasses #-}
module SES.Myers where

import Control.Monad.Free.Freer
import Data.These
import qualified Data.Vector as Vector
import Prologue

data MyersF a where
  SES :: [a] -> [a] -> MyersF [These a a]
  MiddleSnake :: Vector.Vector a -> Vector.Vector a -> MyersF (Snake, EditDistance)
  FindDPath :: Direction -> EditDistance -> Diagonal -> MyersF Endpoint

data For a where
  For :: [a] -> For a
  Continue :: For a

data StepF a where
  M :: MyersF a -> StepF a
  S :: State MyersState a -> StepF a

type Myers = Freer StepF

data Snake = Snake { xy :: Endpoint, uv :: Endpoint }

newtype EditDistance = EditDistance { unEditDistance :: Int }
newtype Diagonal = Diagonal { unDiagonal :: Int }
data Endpoint = Endpoint { x :: !Int, y :: !Int }
data Direction = Forward | Reverse


-- Evaluation

decompose :: MyersF a -> Myers a
decompose myers = case myers of
  SES {} -> return []

  MiddleSnake as bs -> do
    for 0 maxD 1 $ \ d -> do
      for (negate d) d 2 $ \ k -> do
        Endpoint x y <- findDPath Forward (EditDistance d) (Diagonal k)
        return ()

      for (negate d) d 2 $ \ k -> do
        Endpoint x y <- findDPath Reverse (EditDistance d) (Diagonal (k + delta))
        return ()
    return (Snake (Endpoint 0 0) (Endpoint 0 0), EditDistance 0)
    where ceilDiv = (uncurry (+) .) . divMod
          n = length as
          m = length bs
          delta = n - m
          maxD = (m + n) `ceilDiv` 2

          for :: (Real a, Monad m) => a -> a -> a -> (a -> m b) -> m ()
          for from to by with
            | from >= to = with from >> for (from + by) to by with
            | otherwise = return ()

  FindDPath {} -> return (Endpoint 0 0)


-- Smart constructors

findDPath :: Direction -> EditDistance -> Diagonal -> Myers Endpoint
findDPath direction d k = M (FindDPath direction d k) `Then` return


-- Implementation details

data MyersState = MyersState { forward :: !(Vector.Vector Int), backward :: !(Vector.Vector Int), offset :: Diagonal }

getK :: Direction -> Diagonal -> Myers Endpoint
getK direction (Diagonal diagonal) = do
  MyersState forward backward (Diagonal offset) <- get
  let v = case direction of { Forward -> forward ; Reverse -> backward }
  return $! v `at` (offset + diagonal)

at :: Vector.Vector Int -> Int -> Endpoint
at v k = Endpoint (v Vector.! k) 0

overlaps :: Endpoint -> Endpoint -> Bool
overlaps (Endpoint x y) (Endpoint u v) = x - y == u - v && x <= u

inInterval :: Ord a => a -> (a, a) -> Bool
inInterval k (lower, upper) = k >= lower && k <= upper


-- Instances

instance MonadState MyersState Myers where
  get = S get `Then` return
  put a = S (put a) `Then` return
