{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE PackageImports #-}
module Lib
    ( SomeData (..)
    , Codec (..)
    , codecs
    ) where

import Data.Int
import Data.Word
import qualified "binary" Data.Binary as B
import qualified "binary-old" Data.Binary as BO
import qualified Data.Serialize as C
import qualified Data.Vector.Generic as V
import qualified Data.Vector.Generic.Mutable as MV
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy.Builder as Builder
import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L
import Data.Monoid ((<>))
import Data.Vector.Binary ()
import Data.Vector.Serialize ()
import Control.Monad.ST
import Control.DeepSeq
import qualified Data.ByteString.Unsafe as SU
import Data.Bits ((.|.), shiftL)
import Data.ByteString.Internal (ByteString (PS), accursedUnutterablePerformIO, unsafeCreate)
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Storable (peekByteOff, pokeByteOff, Storable, sizeOf)
import Foreign.Ptr (Ptr)
import qualified Data.Vector
import Control.Monad.Primitive (PrimMonad (..))
import GHC.Base   ( unsafeCoerce# )
import Control.Exception (Exception, catch, throwIO)
import Data.Typeable (Typeable)
import qualified Data.Vector.Unboxed.Mutable
import qualified Control.Monad.Fail as Fail
import Unsafe.Coerce (unsafeCoerce)
import GHC.Generics (Generic)
import qualified Data.Binary.Serialise.CBOR as CBOR
import qualified Data.Packer as P
import System.IO.Unsafe (unsafePerformIO)

-------------------------------------------------------------------
-- The datatype we're going to be experimenting with
data SomeData = SomeData !Int64 !Word8 !Double
    deriving (Eq, Show, Generic)
instance NFData SomeData where
    rnf x = x `seq` ()
-------------------------------------------------------------------

-------------------------------------------------------------------
-- Codecs, to make it easier to write the test suite and benchamrks
data Codec where
    Codec :: (NFData binary, Eq binary, Show binary)
          => [(String, Data.Vector.Vector SomeData -> binary)]
          -> [(String, binary -> Maybe (Data.Vector.Vector SomeData))]
          -> Codec

codecs :: [Codec]
codecs =
    [ Codec
        [ ("encodePacker", encodePacker)
        , ("encodeSimpleRaw", encodeSimpleRaw)
        , ("encodeSimplePoke", encodeSimplePoke)
        , ("encodeSimplePokeMonad", encodeSimplePokeMonad)
        , ("encodeSimplePokeRef", encodeSimplePokeRef)
        , ("encodeSimplePokeRefMonad", encodeSimplePokeRefMonad)
        , ("encodeBuilderLE", encodeBuilderLE)
        ]
        [ ("decodePacker", decodePacker)
        , ("decodeSimplePeek", decodeSimplePeek)
        , ("decodeSimplePeekEx", decodeSimplePeekEx)
        , ("decodeRawLE", decodeRawLE)
        ]
    , Codec
        [ ("encodeBuilderBE", encodeBuilderBE)
        , ("encodeCereal", C.encode)
        ]
        [ ("decodeRawBE", decodeRawBE)
        , ("decodeCereal", decodeCereal)
        ]
    , simpleCodec "binary" B.encode decodeBinary
    , simpleCodec "old-binary" BO.encode decodeOldBinary
    , simpleCodec "cbor" CBOR.serialise (Just . CBOR.deserialise)
    ]
  where
    simpleCodec name enc dec = Codec [(name, enc)] [(name, dec)]
-------------------------------------------------------------------

-------------------------------------------------------------------
-- packer package
encodePacker :: (Simple (v SomeData), V.Vector v SomeData)
             => v SomeData
             -> ByteString
encodePacker v = P.runPacking (either id ($ v) simpleSize) $ do
    P.putStorable (fromIntegral $ V.length v :: Int64)
    V.forM_ v $ \(SomeData x y z) -> do
        P.putStorable x
        P.putStorable y
        P.putStorable z
{-# INLINE encodePacker #-}

decodePacker :: V.Vector v SomeData => ByteString -> Maybe (v SomeData)
decodePacker =
    either (const Nothing) Just . P.tryUnpacking go
  where
    go = do
        len :: Int64 <- P.getStorable
        let len' = fromIntegral len
        mv <- return $ unsafePerformIO $ MV.new len'
        let loop i
                | i >= len' = return $ unsafePerformIO $ V.unsafeFreeze mv
                | otherwise = do
                    x <- SomeData
                        <$> P.getStorable
                        <*> P.getStorable
                        <*> P.getStorable
                    !() <- return $ unsafePerformIO $ MV.unsafeWrite mv i x
                    loop $! i + 1
        loop 0
{-# INLINE decodePacker #-}
-------------------------------------------------------------------


-------------------------------------------------------------------
-- binary package
instance B.Binary SomeData

decodeBinary
    :: B.Binary (v SomeData)
    => L.ByteString
    -> Maybe (v SomeData)
decodeBinary = either
            (const Nothing)
            (\(lbs, _, x) ->
                if L.null lbs
                    then Just x
                    else Nothing)
       . B.decodeOrFail
{-# INLINE decodeBinary #-}
-------------------------------------------------------------------

-------------------------------------------------------------------
-- old binary package
instance BO.Binary SomeData where
    put (SomeData x y z) = do
        BO.put x
        BO.put y
        BO.put z
    {-# INLINE put #-}
    get = SomeData <$> BO.get <*> BO.get <*> BO.get
    {-# INLINE get #-}
instance BO.Binary a => BO.Binary (Data.Vector.Vector a) where
    put v = do
        BO.put (V.length v)
        V.mapM_ BO.put v
    {-# INLINE put #-}
    get = do
        len <- BO.get
        mv <- return $ unsafePerformIO $ MV.new len
        let loop i
                | i >= len = return $ unsafePerformIO $ V.unsafeFreeze mv
                | otherwise = do
                    x <- BO.get
                    !() <- return $ unsafePerformIO $ MV.unsafeWrite mv i x
                    loop $! i + 1
        loop 0
    {-# INLINE get #-}

decodeOldBinary :: L.ByteString -> Maybe (Data.Vector.Vector SomeData)
decodeOldBinary = Just . BO.decode
{-# INLINE decodeOldBinary #-}
-------------------------------------------------------------------

-------------------------------------------------------------------
-- cereal package
instance C.Serialize SomeData

decodeCereal
    :: C.Serialize (v SomeData)
    => ByteString
    -> Maybe (v SomeData)
decodeCereal = either (const Nothing) Just . C.decode
{-# INLINE decodeCereal #-}
-------------------------------------------------------------------

-------------------------------------------------------------------
-- cereal package
instance CBOR.Serialise SomeData where
   decode = SomeData <$> CBOR.decode <*> CBOR.decode <*> CBOR.decode
   {-# INLINE decode #-}
   encode (SomeData a b c) = CBOR.encode a <> CBOR.encode b <> CBOR.encode c
   {-# INLINE encode #-}
-------------------------------------------------------------------

-------------------------------------------------------------------
-- low level big-endian (non-host order), using bytestring-builder
encodeBuilderBE :: V.Vector v SomeData => v SomeData -> ByteString
encodeBuilderBE v = L.toStrict
         $ Builder.toLazyByteString
         $ Builder.int64BE (fromIntegral $ V.length v)
        <> V.foldr (\sd b -> go sd <> b) mempty v
  where
    go (SomeData x y z)
        = Builder.int64BE x
       <> Builder.word8 y
       <> Builder.doubleBE z
    {-# INLINE go #-}
{-# INLINE encodeBuilderBE #-}

decodeRawBE
    :: V.Vector v SomeData
    => ByteString
    -> Maybe (v SomeData)
decodeRawBE bs0 = runST $
    readInt64 bs0 $ \bs1 len -> do
        let len' = fromIntegral len
        mv <- MV.new len'
        let loop idx bs
                | idx >= len' = Just <$> V.unsafeFreeze mv
                | otherwise =
                    readInt64  bs  $ \bsX x ->
                    readWord8  bsX $ \bsY y ->
                    readDouble bsY $ \bsZ z -> do
                        MV.unsafeWrite mv idx (SomeData x y z)
                        loop (idx + 1) bsZ
        loop 0 bs1
  where
    readInt64 bs f
        | S.length bs < 8 = return Nothing
        | otherwise = f
            (SU.unsafeDrop 8 bs)
            (fromIntegral $ word64be bs :: Int64)
    {-# INLINE readInt64 #-}

    readWord8 bs f
        | S.length bs < 1 = return Nothing
        | otherwise = f
            (SU.unsafeDrop 1 bs)
            (bs `SU.unsafeIndex` 0)
    {-# INLINE readWord8 #-}

    readDouble bs f
        | S.length bs < 8 = return Nothing
        | otherwise = f
            (SU.unsafeDrop 8 bs)
            -- probably not safe enough for production, but works for basic
            -- benchmarking here
            (unsafeCoerce $ word64be bs :: Double)
    {-# INLINE readDouble #-}
{-# INLINE decodeRawBE #-}

word64be :: ByteString -> Word64
word64be = \s ->
              (fromIntegral (s `SU.unsafeIndex` 0) `shiftL` 56) .|.
              (fromIntegral (s `SU.unsafeIndex` 1) `shiftL` 48) .|.
              (fromIntegral (s `SU.unsafeIndex` 2) `shiftL` 40) .|.
              (fromIntegral (s `SU.unsafeIndex` 3) `shiftL` 32) .|.
              (fromIntegral (s `SU.unsafeIndex` 4) `shiftL` 24) .|.
              (fromIntegral (s `SU.unsafeIndex` 5) `shiftL` 16) .|.
              (fromIntegral (s `SU.unsafeIndex` 6) `shiftL`  8) .|.
              (fromIntegral (s `SU.unsafeIndex` 7) )
{-# INLINE word64be #-}
-------------------------------------------------------------------

-------------------------------------------------------------------
-- low level little-endian (host order), using bytestring-builder
encodeBuilderLE :: V.Vector v SomeData => v SomeData -> ByteString
encodeBuilderLE v = L.toStrict
         $ Builder.toLazyByteString
         $ Builder.int64LE (fromIntegral $ V.length v)
        <> V.foldr (\sd b -> go sd <> b) mempty v
  where
    go (SomeData x y z)
        = Builder.int64LE x
       <> Builder.word8 y
       <> Builder.doubleLE z
    {-# INLINE go #-}
{-# INLINE encodeBuilderLE #-}

decodeRawLE
    :: V.Vector v SomeData
    => ByteString
    -> Maybe (v SomeData)
decodeRawLE bs0 = runST $
    readInt64 bs0 $ \bs1 len -> do
        let len' = fromIntegral len
        mv <- MV.new len'
        let loop idx bs
                | idx >= len' = Just <$> V.unsafeFreeze mv
                | otherwise =
                    readInt64  bs  $ \bsX x ->
                    readWord8  bsX $ \bsY y ->
                    readDouble bsY $ \bsZ z -> do
                        MV.unsafeWrite mv idx (SomeData x y z)
                        loop (idx + 1) bsZ
        loop 0 bs1
  where
    readInt64 bs f
        | S.length bs < 8 = return Nothing
        | otherwise = f
            (SU.unsafeDrop 8 bs)
            (fromIntegral $ word64le bs :: Int64)
    {-# INLINE readInt64 #-}

    readWord8 bs f
        | S.length bs < 1 = return Nothing
        | otherwise = f
            (SU.unsafeDrop 1 bs)
            (bs `SU.unsafeIndex` 0)
    {-# INLINE readWord8 #-}

    readDouble bs f
        | S.length bs < 8 = return Nothing
        | otherwise = f
            (SU.unsafeDrop 8 bs)
            (doublele bs)
    {-# INLINE readDouble #-}
{-# INLINE decodeRawLE #-}

word64le :: ByteString -> Word64
#if 0
word64le = \s ->
              (fromIntegral (s `SU.unsafeIndex` 7) `shiftL` 56) .|.
              (fromIntegral (s `SU.unsafeIndex` 6) `shiftL` 48) .|.
              (fromIntegral (s `SU.unsafeIndex` 5) `shiftL` 40) .|.
              (fromIntegral (s `SU.unsafeIndex` 4) `shiftL` 32) .|.
              (fromIntegral (s `SU.unsafeIndex` 3) `shiftL` 24) .|.
              (fromIntegral (s `SU.unsafeIndex` 2) `shiftL` 16) .|.
              (fromIntegral (s `SU.unsafeIndex` 1) `shiftL`  8) .|.
              (fromIntegral (s `SU.unsafeIndex` 0) )
#endif
word64le (PS x s _) =
    accursedUnutterablePerformIO $ withForeignPtr x $ \p -> peekByteOff p s
{-# INLINE word64le #-}

doublele :: ByteString -> Double
doublele (PS x s _) =
    accursedUnutterablePerformIO $ withForeignPtr x $ \p -> peekByteOff p s
{-# INLINE doublele #-}
-------------------------------------------------------------------

-- Some helper types used below
type Total = Int -- total byte size of the given Ptr
type Offset = Int -- how far into the given Ptr to look

-- | A more efficient @IORef Int@
newtype OffsetRef = OffsetRef
    (Data.Vector.Unboxed.Mutable.MVector RealWorld Offset)

newOffsetRef :: Int -> IO OffsetRef
newOffsetRef x = OffsetRef <$> MV.replicate 1 x
{-# INLINE newOffsetRef #-}

readOffsetRef :: OffsetRef -> IO Int
readOffsetRef (OffsetRef mv) = MV.unsafeRead mv 0
{-# INLINE readOffsetRef #-}

writeOffsetRef :: OffsetRef -> Int -> IO ()
writeOffsetRef (OffsetRef mv) x = MV.unsafeWrite mv 0 x
{-# INLINE writeOffsetRef #-}

-------------------------------------------------------------------
-- continuation-based Peek implementation
newtype Peek s a = Peek
    { runPeek :: forall r byte.
        Total
     -> Ptr byte
     -> Offset
     -> (Offset -> a -> IO (Maybe r))
     -> IO (Maybe r)
    }
    deriving Functor
instance Applicative (Peek s) where
    pure x = Peek (\_ _ offset k -> k offset x)
    {-# INLINE pure #-}
    Peek f <*> Peek g = Peek $ \total ptr offset1 k ->
        f total ptr offset1 $ \offset2 f' ->
        g total ptr offset2 $ \offset3 g' ->
        k offset3 (f' g')
    {-# INLINE (<*>) #-}
    Peek f *> Peek g = Peek $ \total ptr offset1 k ->
        f total ptr offset1 $ \offset2 _ ->
        g total ptr offset2 k
    {-# INLINE (*>) #-}
instance Monad (Peek s) where
    return = pure
    {-# INLINE return #-}
    (>>) = (*>)
    {-# INLINE (>>) #-}
    Peek x >>= f = Peek $ \total ptr offset1 k ->
        x total ptr offset1 $ \offset2 x' ->
        runPeek (f x') total ptr offset2 k
    {-# INLINE (>>=) #-}
    fail = Fail.fail
    {-# INLINE fail #-}
instance Fail.MonadFail (Peek s) where
    fail _ = Peek $ \_ _ _ _ -> pure Nothing
    {-# INLINE fail #-}
instance PrimMonad (Peek s) where
    type PrimState (Peek s) = s
    primitive action = Peek $ \_ _ offset k -> do
        x <- primitive (unsafeCoerce# action)
        k offset x
    {-# INLINE primitive #-}

-- | A @Peek@ implementation based on an instance of @Storable@
storablePeek :: forall s a. Storable a => Peek s a
storablePeek = Peek $ \total ptr offset k ->
    let offset' = offset + needed
        needed = sizeOf (undefined :: a)
     in if total >= offset'
            then do
                x <- peekByteOff ptr offset
                k offset' x
            else return Nothing
{-# INLINE storablePeek #-}
-------------------------------------------------------------------

-------------------------------------------------------------------
-- ref/exception-based Peek implementation
data PeekException = PeekException
    deriving (Show, Typeable)
instance Exception PeekException

newtype PeekEx s a = PeekEx
    { runPeekEx :: forall byte.
        Total
     -> Ptr byte
     -> OffsetRef
     -> IO a
    }
    deriving Functor
instance Applicative (PeekEx s) where
    pure x = PeekEx (\_ _ _ -> pure x)
    {-# INLINE pure #-}
    PeekEx f <*> PeekEx g = PeekEx $ \total ptr ref ->
        f total ptr ref <*> g total ptr ref
    {-# INLINE (<*>) #-}
    PeekEx f *> PeekEx g = PeekEx $ \total ptr ref ->
        f total ptr ref *>
        g total ptr ref
    {-# INLINE (*>) #-}
instance Monad (PeekEx s) where
    return = pure
    {-# INLINE return #-}
    (>>) = (*>)
    {-# INLINE (>>) #-}
    PeekEx x >>= f = PeekEx $ \total ptr ref -> do
        x' <- x total ptr ref
        runPeekEx (f x') total ptr ref
    {-# INLINE (>>=) #-}
    fail = Fail.fail
    {-# INLINE fail #-}
instance Fail.MonadFail (PeekEx s) where
    fail _ = PeekEx $ \_ _ _ -> throwIO PeekException
    {-# INLINE fail #-}
instance PrimMonad (PeekEx s) where
    type PrimState (PeekEx s) = s
    primitive action = PeekEx $ \_ _ _ ->
        primitive (unsafeCoerce# action)
    {-# INLINE primitive #-}

-- | A @PeekEx@ implementation based on an instance of @Storable@
storablePeekEx :: forall s a. Storable a => PeekEx s a
storablePeekEx = PeekEx $ \total ptr offsetRef -> do
    offset <- readOffsetRef offsetRef
    let offset' = offset + needed
        needed = sizeOf (undefined :: a)
    if total >= offset'
        then do
            writeOffsetRef offsetRef offset'
            peekByteOff ptr offset
        else fail "not enough bytes"
{-# INLINE storablePeekEx #-}
-------------------------------------------------------------------

-------------------------------------------------------------------
-- Continuation-based Poke implementation
newtype Poke = Poke
    { runPoke :: forall byte.
        Ptr byte
     -> Offset
     -> (Offset -> IO ())
     -> IO ()
    }
instance Monoid Poke where
    mempty = Poke $ \_ offset f -> f offset
    {-# INLINE mempty #-}
    mappend (Poke f) (Poke g) = Poke $ \ptr offset0 rest ->
        f ptr offset0 $ \offset1 ->
        g ptr offset1 rest
    {-# INLINE mappend #-}

storablePoke :: Storable a => a -> Poke
storablePoke x = Poke $ \ptr offset k -> do
    pokeByteOff ptr offset x
    k $! offset + sizeOf x
{-# INLINE storablePoke #-}
-------------------------------------------------------------------

-------------------------------------------------------------------
-- Continuation-based monadic Poke implementation
newtype PokeMonad a = PokeMonad
    { runPokeMonad :: forall byte r.
        Ptr byte
     -> Offset
     -> (Offset -> a -> IO r)
     -> IO r
    }
    deriving Functor
instance Applicative PokeMonad where
    pure x = PokeMonad $ \_ offset k -> k offset x
    {-# INLINE pure #-}
    PokeMonad f <*> PokeMonad g = PokeMonad $ \ptr offset1 k ->
        f ptr offset1 $ \offset2 f' ->
        g ptr offset2 $ \offset3 g' ->
        k offset3 (f' g')
    {-# INLINE (<*>) #-}
    PokeMonad f *> PokeMonad g = PokeMonad $ \ptr offset1 k ->
        f ptr offset1 $ \offset2 _ ->
        g ptr offset2 $ \offset3 g' ->
        k offset3 g'
    {-# INLINE (*>) #-}
instance Monad PokeMonad where
    return = pure
    {-# INLINE return #-}
    (>>) = (*>)
    {-# INLINE (>>) #-}
    PokeMonad x >>= f = PokeMonad $ \ptr offset1 k ->
        x ptr offset1 $ \offset2 x' ->
        runPokeMonad (f x') ptr offset2 k
    {-# INLINE (>>=) #-}

storablePokeMonad :: Storable a => a -> PokeMonad ()
storablePokeMonad x = PokeMonad $ \ptr offset k -> do
    y <- pokeByteOff ptr offset x
    (k $! offset + sizeOf x) y
{-# INLINE storablePokeMonad #-}
-------------------------------------------------------------------

-------------------------------------------------------------------
-- Reference-based Poke implementation
newtype PokeRef = PokeRef
    { runPokeRef :: forall byte.
        Ptr byte
     -> OffsetRef
     -> IO ()
    }
instance Monoid PokeRef where
    mempty = PokeRef $ \_ _ -> return ()
    {-# INLINE mempty #-}
    mappend (PokeRef f) (PokeRef g) = PokeRef $ \ptr ref ->
        f ptr ref *>
        g ptr ref
    {-# INLINE mappend #-}

storablePokeRef :: Storable a => a -> PokeRef
storablePokeRef x = PokeRef $ \ptr ref -> do
    offset <- readOffsetRef ref
    pokeByteOff ptr offset x
    writeOffsetRef ref $! offset + sizeOf x
{-# INLINE storablePokeRef #-}
-------------------------------------------------------------------

-------------------------------------------------------------------
-- Reference-based monadic Poke implementation
newtype PokeRefMonad a = PokeRefMonad
    { runPokeRefMonad :: forall byte.
        Ptr byte
     -> OffsetRef
     -> IO a
    }
    deriving Functor
instance Applicative PokeRefMonad where
    pure x = PokeRefMonad $ \_ _ -> pure x
    {-# INLINE pure #-}
    PokeRefMonad f <*> PokeRefMonad g = PokeRefMonad $ \ptr ref ->
        f ptr ref <*> g ptr ref
    {-# INLINE (<*>) #-}
    PokeRefMonad f *> PokeRefMonad g = PokeRefMonad $ \ptr ref ->
        f ptr ref *> g ptr ref
    {-# INLINE (*>) #-}
instance Monad PokeRefMonad where
    return = pure
    {-# INLINE return #-}
    (>>) = (*>)
    {-# INLINE (>>) #-}
    PokeRefMonad x >>= f = PokeRefMonad $ \ptr ref -> do
        x' <- x ptr ref
        runPokeRefMonad (f x') ptr ref
    {-# INLINE (>>=) #-}

storablePokeRefMonad :: Storable a => a -> PokeRefMonad ()
storablePokeRefMonad x = PokeRefMonad $ \ptr ref -> do
    offset <- readOffsetRef ref
    pokeByteOff ptr offset x
    writeOffsetRef ref $! offset + sizeOf x
{-# INLINE storablePokeRefMonad #-}
-------------------------------------------------------------------

-------------------------------------------------------------------

-- | A Simple serialization typeclass. Includes both @Peek@ and @PeekEx@
-- implementations, though in a real library we would just choose the faster
-- implementation.
class Simple a where
    simpleSize :: Either Int (a -> Int)
    default simpleSize :: Storable a => Either Int (a -> Int)
    simpleSize = Left (sizeOf (undefined :: a))
    {-# INLINE simpleSize #-}

    simpleRawPoke :: Ptr byte -> Int -> a -> IO ()
    default simpleRawPoke :: Storable a => Ptr byte -> Int -> a -> IO ()
    simpleRawPoke = pokeByteOff
    {-# INLINE simpleRawPoke #-}

    simplePoke :: a -> Poke
    default simplePoke :: Storable a => a -> Poke
    simplePoke = storablePoke
    {-# INLINE simplePoke #-}

    simplePokeMonad :: a -> PokeMonad ()
    default simplePokeMonad :: Storable a => a -> PokeMonad ()
    simplePokeMonad = storablePokeMonad
    {-# INLINE simplePokeMonad #-}

    simplePokeRef :: a -> PokeRef
    default simplePokeRef :: Storable a => a -> PokeRef
    simplePokeRef = storablePokeRef
    {-# INLINE simplePokeRef #-}

    simplePokeRefMonad :: a -> PokeRefMonad ()
    default simplePokeRefMonad :: Storable a => a -> PokeRefMonad ()
    simplePokeRefMonad = storablePokeRefMonad
    {-# INLINE simplePokeRefMonad #-}

    simplePeek :: Peek s a
    default simplePeek :: Storable a => Peek s a
    simplePeek = storablePeek
    {-# INLINE simplePeek #-}

    simplePeekEx :: PeekEx s a
    default simplePeekEx :: Storable a => PeekEx s a
    simplePeekEx = storablePeekEx
    {-# INLINE simplePeekEx #-}

instance Simple Int64
instance Simple Word8
instance Simple Double

instance Simple SomeData where
    simpleSize = Left 17
    simpleRawPoke p s (SomeData x y z) = do
        simpleRawPoke p s x
        simpleRawPoke p (s + 8) y
        simpleRawPoke p (s + 9) z
    simplePoke (SomeData x y z) =
        simplePoke x <>
        (simplePoke y <>
        simplePoke z)
    simplePokeMonad (SomeData x y z) = do
        simplePokeMonad x
        simplePokeMonad y
        simplePokeMonad z
    simplePokeRef (SomeData x y z) =
        simplePokeRef x <>
        simplePokeRef y <>
        simplePokeRef z
    simplePokeRefMonad (SomeData x y z) = do
        simplePokeRefMonad x
        simplePokeRefMonad y
        simplePokeRefMonad z
    simplePeek = SomeData
        <$> simplePeek
        <*> simplePeek
        <*> simplePeek
    simplePeekEx = SomeData
        <$> simplePeekEx
        <*> simplePeekEx
        <*> simplePeekEx
    {-# INLINE simpleSize #-}
    {-# INLINE simpleRawPoke #-}
    {-# INLINE simplePoke #-}
    {-# INLINE simplePokeMonad #-}
    {-# INLINE simplePokeRef #-}
    {-# INLINE simplePokeRefMonad #-}
    {-# INLINE simplePeek #-}
    {-# INLINE simplePeekEx #-}

instance Simple a => Simple (Data.Vector.Vector a) where
    simpleSize = Right $ \v ->
        case simpleSize of
            Left s -> s * V.length v + 8
            Right f -> V.sum (V.map f v) + 8
    simpleRawPoke p s v = do
        simpleRawPoke p s (fromIntegral (V.length v) :: Int64)
        let getSize =
                case simpleSize of
                    Left x -> const x
                    Right f -> f
            loop i s'
                | i >= V.length v = return ()
                | otherwise = do
                    let x = V.unsafeIndex v i
                    simpleRawPoke p s' x
                    loop (i + 1) (s' + getSize x)
        loop 0 (s + 8)
    simplePoke v =
        -- TODO: This is _much_ slower with foldMap, try to come up with a
        -- smaller demonstration of the problem
        simplePoke (fromIntegral (V.length v) :: Int64) <>
        V.foldr (mappend . simplePoke) mempty v
    simplePokeMonad v = do
        simplePokeMonad (fromIntegral (V.length v) :: Int64)
        V.mapM_ simplePokeMonad v
    simplePokeRef v =
        simplePokeRef (fromIntegral (V.length v) :: Int64) <>
        V.foldr (mappend . simplePokeRef) mempty v
    simplePokeRefMonad v = do
        simplePokeRefMonad (fromIntegral (V.length v) :: Int64)
        V.mapM_ simplePokeRefMonad v
    simplePeek = do
        len :: Int64 <- simplePeek
        let len' = fromIntegral len
        mv <- MV.new len'
        let loop i
                | i >= len' = V.unsafeFreeze mv
                | otherwise = do
                    x <- simplePeek
                    MV.unsafeWrite mv i x
                    loop $! i + 1
        loop 0
    simplePeekEx = do
        len :: Int64 <- simplePeekEx
        let len' = fromIntegral len
        mv <- MV.new len'
        let loop i
                | i >= len' = V.unsafeFreeze mv
                | otherwise = do
                    x <- simplePeekEx
                    MV.unsafeWrite mv i x
                    loop $! i + 1
        loop 0
    {-# INLINE simpleSize #-}
    {-# INLINE simpleRawPoke #-}
    {-# INLINE simplePoke #-}
    {-# INLINE simplePokeMonad #-}
    {-# INLINE simplePokeRef #-}
    {-# INLINE simplePokeRefMonad #-}
    {-# INLINE simplePeek #-}
    {-# INLINE simplePeekEx #-}

-------------------------------------------------------------------

-------------------------------------------------------------------
-- Encode/decode functions based on the Simple class

-- | Allocates exactly the amount of storage space necessary
encodeSimpleRaw :: Simple a => a -> ByteString
encodeSimpleRaw x = unsafeCreate
    (either id ($ x) simpleSize)
    (\p -> simpleRawPoke p 0 x)
{-# INLINE encodeSimpleRaw #-}

encodeSimplePoke :: Simple a => a -> ByteString
encodeSimplePoke x = unsafeCreate
    (either id ($ x) simpleSize)
    (\p -> runPoke (simplePoke x) p 0 (\_off -> return ()))
{-# INLINE encodeSimplePoke #-}

encodeSimplePokeMonad :: Simple a => a -> ByteString
encodeSimplePokeMonad x = unsafeCreate
    (either id ($ x) simpleSize)
    (\p -> runPokeMonad (simplePokeMonad x) p 0 (\_ _ -> return ()))
{-# INLINE encodeSimplePokeMonad #-}

encodeSimplePokeRef :: Simple a => a -> ByteString
encodeSimplePokeRef x = unsafeCreate
    (either id ($ x) simpleSize)
    (\p -> do
        ref <- newOffsetRef 0
        runPokeRef (simplePokeRef x) p ref)
{-# INLINE encodeSimplePokeRef #-}

encodeSimplePokeRefMonad :: Simple a => a -> ByteString
encodeSimplePokeRefMonad x = unsafeCreate
    (either id ($ x) simpleSize)
    (\p -> do
        ref <- newOffsetRef 0
        runPokeRefMonad (simplePokeRefMonad x) p ref)
{-# INLINE encodeSimplePokeRefMonad #-}

-- | Decode using the @Peek@ continuation-passing approach
decodeSimplePeek :: Simple a => ByteString -> Maybe a
decodeSimplePeek (PS x s len) =
    accursedUnutterablePerformIO $ withForeignPtr x $ \p ->
        let total = len + s
            final offset y
                | offset == total = return (Just y)
                | otherwise = return Nothing
         in runPeek simplePeek (len + s) p s final
{-# INLINE decodeSimplePeek #-}

-- | Decode using the @PeekEx@ ref/exception approach
decodeSimplePeekEx :: Simple a => ByteString -> Maybe a
decodeSimplePeekEx (PS x s len) =
    accursedUnutterablePerformIO $ withForeignPtr x $ \p -> do
        let total = len + s
        offsetRef <- newOffsetRef s
        let runner = do
                y <- runPeekEx simplePeekEx (len + s) p offsetRef
                offset <- readOffsetRef offsetRef
                return $ if offset == total
                    then Just y
                    else Nothing
        runner `catch` \PeekException -> return Nothing
{-# INLINE decodeSimplePeekEx #-}
-------------------------------------------------------------------
