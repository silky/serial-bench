import Criterion.Main
import Lib
import qualified Data.Vector as V
import Data.ByteString (ByteString)

main :: IO ()
main = do
    let sds = V.map (\i -> SomeData i (i + 1) (i + 2))
            $ V.enumFromTo 1 100
        bs = encode sds
        bsLE = encodeLE sds
    defaultMain
        [ bench "binary" $ nf (asVector binary) bs
        , bench "cereal" $ nf (asVector cereal) bs
        , bench "simple" $ nf (asVector simple) bs
        , bench "simpleLE" $ nf (asVector simpleLE) bsLE
        ]

asVector :: (ByteString -> Maybe (V.Vector SomeData))
         -> (ByteString -> Maybe (V.Vector SomeData))
asVector = id
