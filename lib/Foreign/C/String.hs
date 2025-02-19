module Foreign.C.String(
  CString, CStringLen,
  newCAString, newCAStringLen,
  peekCAString, peekCAStringLen,
  withCAString, withCAStringLen,
  newCString, newCStringLen,
  peekCString, peekCStringLen,
  withCString, withCStringLen,
  ) where
import qualified Prelude()              -- do not import Prelude
import Primitives
import Data.Char_Type
import Foreign.C.Types (CChar)
import Foreign.Marshal.Alloc

primNewCAStringLen :: [Char] -> IO (Ptr CChar, Int)
primNewCAStringLen = _primitive "newCAStringLen"

primPeekCAString :: Ptr CChar -> IO [Char]
primPeekCAString = _primitive "peekCAString"

primPeekCAStringLen :: Ptr CChar -> Int -> IO [Char]
primPeekCAStringLen = _primitive "peekCAStringLen"

type CString = Ptr CChar
type CStringLen = (Ptr CChar, Int)

newCAString :: String -> IO CString
newCAString s = primNewCAStringLen s `primBind` \ (s, _) -> primReturn s

newCAStringLen :: String -> IO CStringLen
newCAStringLen = primNewCAStringLen

withCAString :: forall a . String -> (CString -> IO a) -> IO a
withCAString s io =
  newCAString s `primBind` \ cs ->
  io cs `primBind` \ a ->
  free cs `primThen`
  primReturn a

withCAStringLen :: forall a . String -> (CStringLen -> IO a) -> IO a
withCAStringLen s io =
  newCAStringLen s `primBind` \ cs@(p, _) ->
  io cs `primBind` \ a ->
  free p `primThen`
  primReturn a

peekCAString :: CString -> IO String
peekCAString = primPeekCAString

peekCAStringLen :: CStringLen -> IO String
peekCAStringLen (p, i) = primPeekCAStringLen p i

------------------------------------------------------
-- XXX:  No encoding!

newCString :: String -> IO CString
newCString = newCAString

newCStringLen :: String -> IO CStringLen
newCStringLen = newCAStringLen

withCString :: forall a . String -> (CString -> IO a) -> IO a
withCString = withCAString

withCStringLen :: forall a . String -> (CStringLen -> IO a) -> IO a
withCStringLen = withCAStringLen

peekCString :: CString -> IO String
peekCString = peekCAString

peekCStringLen :: CStringLen -> IO String
peekCStringLen = peekCAStringLen
