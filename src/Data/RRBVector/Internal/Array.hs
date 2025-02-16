{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE UnboxedTuples #-}

-- Warning: No bound checks are performed!

module Data.RRBVector.Internal.Array
    ( Array, MutableArray
    , empty, singleton, from2
    , replicate, replicateSnoc
    , index, head, last
    , update, adjust, adjust'
    , take, drop, splitAt
    , snoc, cons
    , map, map'
    , traverse, traverse'
    , new, read, write
    , freeze, thaw
    ) where

import Control.Applicative (Applicative(liftA2))
import Control.DeepSeq (NFData(..))
import Control.Monad (when)
import Control.Monad.ST
import Data.Foldable (Foldable(..))
import Data.Primitive.SmallArray
import Prelude hiding (replicate, take, drop, splitAt, head, last, map, traverse, read)

-- start length array
data Array a = Array !Int !Int !(SmallArray a)
data MutableArray s a = MutableArray !Int !Int !(SmallMutableArray s a)

instance Semigroup (Array a) where
    Array start1 len1 arr1 <> Array start2 len2 arr2 = Array 0 len' $ runSmallArray $ do
        sma <- newSmallArray len' uninitialized
        copySmallArray sma 0 arr1 start1 len1
        copySmallArray sma len1 arr2 start2 len2
        pure sma
      where
        !len' = len1 + len2

instance Foldable Array where
    foldr f = \z (Array start len arr) ->
        let !end = start + len
            go i
                | i == end = z
                | (# x #) <- indexSmallArray## arr i = f x (go (i + 1))
        in go start
    {-# INLINE foldr #-}

    foldl f = \z (Array start len arr) ->
        let go i
                | i < start = z
                | (# x #) <- indexSmallArray## arr i = f (go (i - 1)) x
        in go (start + len - 1)
    {-# INLINE foldl #-}

    foldr' f = \z (Array start len arr) ->
        let go i !acc
                | i < start = acc
                | (# x #) <- indexSmallArray## arr i = go (i - 1) (f x acc)
        in go (start + len - 1) z
    {-# INLINE foldr' #-}

    foldl' f = \z (Array start len arr) ->
        let !end = start + len
            go i !acc
                | i == end = acc
                | (# x #) <- indexSmallArray## arr i = go (i + 1) (f acc x)
        in go start z
    {-# INLINE foldl' #-}

    null arr = length arr == 0
    {-# INLINE null #-}

    length (Array _ len _) = len
    {-# INLINE length #-}

instance (NFData a) => NFData (Array a) where
    rnf = foldl' (\_ x -> rnf x) ()

uninitialized :: a
uninitialized = errorWithoutStackTrace "uninitialized"

empty :: Array a
empty = Array 0 0 $ runSmallArray (newSmallArray 0 uninitialized)

singleton :: a -> Array a
singleton x = Array 0 1 $ runSmallArray (newSmallArray 1 x)

from2 :: a -> a -> Array a
from2 x y = Array 0 2 $ runSmallArray $ do
    sma <- newSmallArray 2 x
    writeSmallArray sma 1 y
    pure sma

replicate :: Int -> a -> Array a
replicate n x = Array 0 n $ runSmallArray (newSmallArray n x)

-- > replicateSnoc n x y = snoc (replicate n x) y
replicateSnoc :: Int -> a -> a -> Array a
replicateSnoc n x y = Array 0 len $ runSmallArray $ do
    sma <- newSmallArray len x
    writeSmallArray sma n y
    pure sma
  where
    len = n + 1

index :: Array a -> Int -> a
index (Array start _ arr) idx = indexSmallArray arr (start + idx)

update :: Array a -> Int -> a -> Array a
update (Array start len sa) idx x = Array 0 len $ runSmallArray $ do
    sma <- thawSmallArray sa start len
    writeSmallArray sma idx x
    pure sma

adjust :: Array a -> Int -> (a -> a) -> Array a
adjust (Array start len sa) idx f = Array 0 len $ runSmallArray $ do
    sma <- thawSmallArray sa start len
    x <- indexSmallArrayM sa (start + idx)
    writeSmallArray sma idx (f x)
    pure sma

adjust' :: Array a -> Int -> (a -> a) -> Array a
adjust' (Array start len sa) idx f = Array 0 len $ runSmallArray $ do
    sma <- thawSmallArray sa start len
    x <- indexSmallArrayM sa (start + idx)
    writeSmallArray sma idx $! f x
    pure sma

take :: Array a -> Int -> Array a
take (Array start _ arr) n = Array start n arr

drop :: Array a -> Int -> Array a
drop (Array start len arr) n = Array (start + n) (len - n) arr

splitAt :: Array a -> Int -> (Array a, Array a)
splitAt arr idx = (take arr idx, drop arr idx)

head :: Array a -> a
head arr = index arr 0

last :: Array a -> a
last arr = index arr (length arr - 1)

snoc :: Array a -> a -> Array a
snoc (Array _ len arr) x = Array 0 len' $ runSmallArray $ do
    sma <- newSmallArray len' x
    copySmallArray sma 0 arr 0 len
    pure sma
  where
    !len' = len + 1

cons :: Array a -> a -> Array a
cons (Array _ len arr) x = Array 0 len' $ runSmallArray $ do
    sma <- newSmallArray len' x
    copySmallArray sma 1 arr 0 len
    pure sma
  where
    !len' = len + 1

map :: (a -> b) -> Array a -> Array b
map f (Array start len arr) = Array 0 len $ runSmallArray $ do
    sma <- newSmallArray len uninitialized
    -- i is the index in arr, j is the index in sma
    let loop i j = when (j < len) $ do
            x <- indexSmallArrayM arr i
            writeSmallArray sma j (f x)
            loop (i + 1) (j + 1)
    loop start 0
    pure sma

map' :: (a -> b) -> Array a -> Array b
map' f (Array start len arr) = Array 0 len $ runSmallArray $ do
    sma <- newSmallArray len uninitialized
    -- i is the index in arr, j is the index in sma
    let loop i j = when (j < len) $ do
            x <- indexSmallArrayM arr i
            writeSmallArray sma j $! f x
            loop (i + 1) (j + 1)
    loop start 0
    pure sma

newtype STA a = STA (forall s. SmallMutableArray s a -> ST s (SmallArray a))

runSTA :: Int -> STA a -> Array a
runSTA len (STA m) = Array 0 len (runST $ newSmallArray len uninitialized >>= m)

traverse :: (Applicative f) => (a -> f b) -> Array a -> f (Array b)
traverse f (Array start len arr) =
    -- i is the index in arr, j is the index in sma
    let go i j
            | j == len = pure $ STA unsafeFreezeSmallArray
            | (# x #) <- indexSmallArray## arr i = liftA2 (\y (STA m) -> STA $ \sma -> writeSmallArray sma j y *> m sma) (f x) (go (i + 1) (j + 1))
    in runSTA len <$> go start 0

traverse' :: (Applicative f) => (a -> f b) -> Array a -> f (Array b)
traverse' f (Array start len arr) =
    -- i is the index in arr, j is the index in sma
    let go i j
            | j == len = pure $ STA unsafeFreezeSmallArray
            | (# x #) <- indexSmallArray## arr i = liftA2 (\ !y (STA m) -> STA $ \sma -> writeSmallArray sma j y *> m sma) (f x) (go (i + 1) (j + 1))
    in runSTA len <$> go start 0

new :: Int -> ST s (MutableArray s a)
new len = MutableArray 0 len <$> newSmallArray len uninitialized

read :: MutableArray s a -> Int -> ST s a
read (MutableArray start _ arr) idx = readSmallArray arr (start + idx)

write :: MutableArray s a -> Int -> a -> ST s ()
write (MutableArray start _ arr) idx = writeSmallArray arr (start + idx)

freeze :: MutableArray s a -> Int -> Int -> ST s (Array a)
freeze (MutableArray start _ arr) idx len = Array 0 len <$> freezeSmallArray arr (start + idx) len

thaw :: Array a -> Int -> Int -> ST s (MutableArray s a)
thaw (Array start _ arr) idx len = MutableArray 0 len <$> thawSmallArray arr (start + idx) len
