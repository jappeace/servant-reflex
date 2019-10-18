{-# LANGUAGE AllowAmbiguousTypes   #-}
{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE InstanceSigs          #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}

module Servant.Reflex.RequestAPI where

import           Control.Arrow               (first, second)
import           Control.Lens
import qualified Data.ByteString.Lazy        as BL
import           Data.CaseInsensitive        (mk)
import           Data.Generics.Product
import qualified Data.List                   as L
import qualified Data.Map                    as M
import           Data.Maybe                  (catMaybes)
import           Data.Proxy
import           Data.Semigroup              ((<>))
import qualified Data.Set                    as Set
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import qualified Data.Text.Encoding          as E
import           GHC.Generics
import           GHC.TypeLits                (KnownSymbol, symbolVal)
import           Language.Javascript.JSaddle (MonadJSM)
import           Reflex                      hiding (HList (..))
import           Reflex.Dom.Old
import           Reflex.Dom.Xhr
import           Servant.API                 hiding (HList (..))
import           Servant.Client.Core         (EmptyClient)
import           Servant.Common.BaseUrl
import           Servant.Common.Req          hiding (QueryPart (..))

import           Reflex.Dom.Widget           hiding (HList (..))

import           Servant.Reflex              (BuildHeaderKeysTo (..), toHeaders)

{-
TODO:
 - [x] :<|>
 - [x] Verb content
 - [x] Verb nocontent
 - [x] Verb (Headers content)
 - [x] Verb (Headers nocontent)
 - [ ] Stream
 - [X] Capture :> ...
 - [ ] Capture' :> ...
 - [x] CaptureAll :> ...
 - [x] QueryParam :> ...
 - [x] QueryParams :> ...
 - [x] QueryFlag :> ...
 - [x] ReqBody :> ...
 - [ ] Header' :> ...
 - [x] Header :> ...
 - [x] Summary :> ...
 - [x] Description :> ...
 - [x] path :> ...
 - [ ] RemoteHost :> ...
 - [x] IsSecure :> ...
 - [x] Vault :> ...
 - [ ] WithNamedContext :> ...
 - [ ] AuthenticatedRequest :> ...
 - [x] BasicAuth :> ...
 - [ ] EmptyClient :> ...
 - [ ] EmptyClient
 - [ ] HttpVersion :> ...
-}
data HList xs where
  HNil :: HList '[]
  HCons :: x -> HList xs -> HList (x ': xs)

clientR :: forall t m layout f . (HasClientR t m (Seal layout) f, Applicative f, Reflex t)
        => Proxy layout -> Proxy (m :: * -> *) -> Proxy t -> Proxy f
        -> Dynamic t BaseUrl -> ClientR t m (Seal layout) f
clientR _ mP tP fP url =
  clientRWithRoute (Proxy :: Proxy (Seal layout)) mP fP undefined url undefined

-- | A class for generating top-level the API client function
class HasClientR t (m :: * -> *) api (f :: * -> *) where
  type ClientR t m api f :: *
  clientRWithRoute :: Proxy api -> Proxy m -> Proxy f
                   -> Dynamic t (f (Req t)) -> Dynamic t BaseUrl
                   -> ClientOptions -> ClientR t m api f

-- instance EndpointR t m Raw f where
--   type EInputs t m Raw f = '[XhrRequest T.Text]
--   type EOutput t m Raw f = XhrResponse

--   mkReq (HCons (XhrRequest method url conf) NHil) =
--     ReqR method


-- | A class for generating endpoint-level API client functions
--   We need two separate type classes because the needs of endpoints
--   and top-level clients are incompatible
--
--   Endpoints need to accumulate a list of their input types from
--   the API definition (the @EInputs@ associated type) when building
--   up a function from a sequence of @:>@ combinators. But for
--   sequences of @:<|>@ combinators, such a listing doesn't make
--   sense. So, we use one class for endpoint-level recursion and
--   another for collecting endpoints into the top-level API
class EndpointR t m api f where

  type EInputs        t m api f :: [*]
  type EOutput        t m api f :: *

  mkReq :: HList (EInputs t m api f) -> ReqR
  getResp :: XhrResponse -> EOutput t m api f


------------------------------------------------------------------------------
-- | :<|> APIs
instance {-# OVERLAPPING #-}
  (HasClientR t m (layoutLeft) f,
    HasClientR t m (layoutRight) f
  ) => HasClientR t m (layoutLeft :<|> layoutRight) f where
  type ClientR t m (layoutLeft :<|> layoutRight) f =
    ClientR t m layoutLeft f :<|> ClientR t m layoutRight f
  clientRWithRoute _ tP mP _ url opts =
    clientRWithRoute (Proxy @layoutLeft) tP mP undefined url opts
    :<|>
    clientRWithRoute (Proxy @layoutRight) tP mP undefined url opts

#if MIN_VERSION_servant (0,13,0)
-- TODO: Untested
instance HasClientR t m EmptyClient f where
  type ClientR t m api f = EmptyClient
  clientRWithRoute _ _ _ _ _ _ = EmptyClient
#endif


class ToTuple xs where
  type Tuple xs :: *
  toTuple :: xs -> Tuple xs
  fromTuple :: Tuple xs -> xs

data Sealed a
data SealedRaw

type family Seal a where
  Seal (a :<|> b) = Seal a :<|> Seal b
  Seal Raw = SealedRaw
  Seal a = Sealed a


-- | Turn a single Endpoint into a client, by turning the input HList
--   into a tuple
instance {-# OVERLAPPING #-} forall t m layout f .(EndpointR t m layout f,
          ToTuple (HList (EInputs t m layout f)),
          Monad m
          , Traversable f
          , SupportsServantReflex t m
         ) => HasClientR t (m :: * -> *) (Sealed layout) (f :: * -> *) where
  type ClientR t m (Sealed layout) f =
    Event t (f (Tuple (HList (EInputs t m layout f))))
    -> m (Event t (f (EOutput t m layout f)))
  clientRWithRoute _ mP fP dReq url opts (reqs :: Event t (f (Tuple (HList (EInputs t m layout f ))))) = do
    let reqTuples = fmap (fromTuple @(HList (EInputs t m layout f ))) <$> reqs

        -- TODO: replace these 2 lines w/ the next 2. The trace is for library debugging
        reqRs     = traceEventWith (concat . fmap ((<> "\n") . show)) $ fmap (mkReq @t @m @layout @f) <$> reqTuples
        reqs'     = ffor (attachPromptlyDyn url reqRs) $ \(bUrl, rs) -> mkXhrRequest bUrl <$> rs
        -- reqs'      = ffor (attachPromptlyDyn url reqTuples) $ \(bUrl, inputs) ->
        --                mkXhrRequest bUrl .  mkReq @t @m @layout @f <$> inputs
    resps <- performRequestsAsync $ reqs'
    return (fmap (getResp @t @m @layout @f) <$> resps)


instance (SupportsServantReflex t m, Traversable f) => HasClientR t m SealedRaw f where
  type ClientR t m SealedRaw f = Event t (f (XhrRequest T.Text)) -> m (Event t (f XhrResponse))
  clientRWithRoute _ mP fP dReq url opts reqs = performRequestsAsync reqs


instance {-# OVERLAPPING #-}(MimeUnrender ct a, ReflectMethod method, cts' ~ (ct ': cts), SupportsServantReflex t m, Applicative f
         ) => EndpointR t m (Verb method status cts' a) f where
  type EInputs t m (Verb method status cts' a) f = '[]
  type EOutput t m (Verb method status cts' a) f = Either String a

  mkReq _ = emptyReqR . E.decodeUtf8 $ reflectMethod (Proxy @method)
  getResp resp = case _xhrResponse_response resp of
    Just (XhrResponseBody_ArrayBuffer x) -> mimeUnrender (Proxy @ct) (BL.fromStrict x)

instance {-# OVERLAPPING #-}(ReflectMethod method, SupportsServantReflex t m, Applicative f
         ) => EndpointR t m (Verb method status cts' NoContent) f where
  type EInputs t m (Verb method status cts' NoContent) f = '[]
  type EOutput t m (Verb method status cts' NoContent) f = Either String NoContent

  mkReq _ = emptyReqR . E.decodeUtf8 $ reflectMethod (Proxy @method)
  getResp resp = Right NoContent -- TODO: Should EOutput be `NoContent` rather than Either... ?


instance {-# OVERLAPPING #-}
         (MimeUnrender ct a,
          BuildHeadersTo hs,
          ReflectMethod method, cts' ~ (ct ': cts),
          SupportsServantReflex t m,
          Applicative f,
          BuildHeaderKeysTo hs
         ) => EndpointR t m (Verb method status cts' (Headers hs a)) f where
  type EInputs t m (Verb method status cts' (Headers hs a)) f = '[]
  type EOutput t m (Verb method status cts' (Headers hs a)) f = Either String (Headers hs a)

  mkReq _ = set (field @"reqRRespHeaders") (OnlyHeaders (Set.fromList (buildHeaderKeysTo (Proxy @hs)))) $ emptyReqR $ E.decodeUtf8 $ reflectMethod (Proxy @method)
  getResp resp = case _xhrResponse_response resp of
    Just (XhrResponseBody_ArrayBuffer x) ->
      let hs = buildHeadersTo
               . fmap (first (mk . E.encodeUtf8) . second E.encodeUtf8)
               . M.toList
               $ _xhrResponse_headers resp
      in fmap (flip Headers (hs)) $ mimeUnrender (Proxy @ct) (BL.fromStrict x)


instance {-# OVERLAPPING #-}(MimeUnrender ct a,
          BuildHeadersTo hs,
          BuildHeaderKeysTo hs,
          ReflectMethod method,
          SupportsServantReflex t m,
          Applicative f
         ) => EndpointR t m (Verb method status cts' (Headers hs NoContent)) f where
  type EInputs t m (Verb method status cts' (Headers hs NoContent)) f = '[]
  type EOutput t m (Verb method status cts' (Headers hs NoContent)) f = Either String (Headers hs NoContent)

  mkReq _ = set (field @"reqRRespHeaders") (OnlyHeaders (Set.fromList (buildHeaderKeysTo (Proxy @hs)))) $ emptyReqR . E.decodeUtf8 $ reflectMethod (Proxy @method)
  getResp resp = case _xhrResponse_response resp of
    Just (XhrResponseBody_ArrayBuffer x) ->
      let hs = buildHeadersTo
               . fmap (first (mk . E.encodeUtf8) . second E.encodeUtf8)
               . M.toList
               $ _xhrResponse_headers resp
      in Right (Headers NoContent hs)


instance (SupportsServantReflex t m,
          ToHttpApiData a,
          EndpointR t m sublayout f,
          Applicative f
         ) => EndpointR t m (Capture capture a :> sublayout) f where

  type EInputs t m (Capture capture a :> sublayout) f = a ': EInputs t m sublayout f
  type EOutput t m (Capture capture a :> sublayout) f = EOutput t m sublayout f

  mkReq (HCons x xs) = (\a -> over (field @"reqRPathParts") (toUrlPiece a:)) x $
                       mkReq @t @m @sublayout @f xs

  getResp = getResp @t @m @sublayout @f

instance (SupportsServantReflex t m,
          ToHttpApiData a,
          EndpointR t m sublayout f,
          Applicative f
         ) => EndpointR t m (CaptureAll capture a :> sublayout) f where

  type EInputs t m (CaptureAll capture a :> sublayout) f = [a] ': EInputs t m sublayout f
  type EOutput t m (CaptureAll capture a :> sublayout) f = EOutput t m sublayout f

  mkReq (HCons x xs) = (\a -> over (field @"reqRPathParts") (fmap toUrlPiece a <>)) x $
                       mkReq @t @m @sublayout @f xs

  getResp = getResp @t @m @sublayout @f


instance (SupportsServantReflex t m,
          KnownSymbol sym,
          EndpointR t m sublayout f,
          Applicative f
         ) => EndpointR t m (sym :> sublayout) f where

  type EInputs t m (sym :> sublayout) f = EInputs t m sublayout f
  type EOutput t m (sym :> sublayout) f = EOutput t m sublayout f

  mkReq r = over (field @"reqRPathParts") (T.pack (symbolVal (Proxy @sym)) :) $ mkReq @t @m @sublayout @f r

  getResp = getResp @t @m @sublayout @f

instance (SupportsServantReflex t m,
          ToHttpApiData a,
          EndpointR t m sublayout f,
          KnownSymbol sym,
          Applicative f
         ) => EndpointR t m (QueryParam sym a :> sublayout) f where

  type EInputs t m (QueryParam sym a :> sublayout) f = Maybe a ': EInputs t m sublayout f
  type EOutput t m (QueryParam sym a :> sublayout) f = EOutput t m sublayout f

  mkReq (HCons x xs) = over (field @"reqRParams") ((T.pack $ symbolVal (Proxy @sym),
                                                   QueryPartParam $ fmap (toQueryParam) x) : ) $
    mkReq @t @m @sublayout @f xs


  getResp = getResp @t @m @sublayout @f

instance (SupportsServantReflex t m,
          ToHttpApiData a,
          EndpointR t m sublayout f,
          KnownSymbol sym,
          Applicative f
         ) => EndpointR t m (QueryParams sym a :> sublayout) f where

  type EInputs t m (QueryParams sym a :> sublayout) f = [a] ': EInputs t m sublayout f
  type EOutput t m (QueryParams sym a :> sublayout) f = EOutput t m sublayout f

  mkReq (HCons x xs) =
    let newParams = (T.pack (symbolVal (Proxy @sym)), QueryPartParams (toQueryParam <$> x))
    in over (field @"reqRParams") (newParams :) $ mkReq @t @m @sublayout @f xs

  getResp = getResp @t @m @sublayout @f

instance (SupportsServantReflex t m,
          EndpointR t m sublayout f,
          KnownSymbol sym,
          Applicative f
         ) => EndpointR t m (QueryFlag sym :> sublayout) f where

  type EInputs t m (QueryFlag sym :> sublayout) f = Bool ': EInputs t m sublayout f
  type EOutput t m (QueryFlag sym :> sublayout) f = EOutput t m sublayout f

  mkReq (HCons x xs) =
    let newParam = (T.pack (symbolVal (Proxy @sym)), QueryPartFlag x)
    in over (field @"reqRParams") (newParam :) $ mkReq @t @m @sublayout @f xs

  getResp = getResp @t @m @sublayout @f

instance (SupportsServantReflex t m,
          EndpointR t m sublayout f,
          MimeRender ct a,
          Applicative f
         ) => EndpointR t m (ReqBody (ct ': cts) a :> sublayout) f where


  type EInputs t m (ReqBody (ct ': cts) a :> sublayout) f = a ': EInputs t m sublayout f
  type EOutput t m (ReqBody (ct ': cts) a :> sublayout) f = EOutput t m sublayout f

  mkReq (HCons x xs) =
    set (field @"reqRBody") (Just (mimeRender (Proxy @ct) x, T.pack (show (contentType (Proxy @ct))))) $ mkReq @t @m @sublayout @f xs

  getResp = getResp @t @m @sublayout @f


instance (SupportsServantReflex t m,
          EndpointR t m sublayout f,
          KnownSymbol sym,
          ToHttpApiData a,
          Applicative f
         ) => EndpointR t m (Header sym a :> sublayout) f where


  type EInputs t m (Header sym a :> sublayout) f = a ': EInputs t m sublayout f
  type EOutput t m (Header sym a :> sublayout) f = EOutput t m sublayout f

  mkReq (HCons x xs) =
    over (field @"reqRHeaders")
         -- ((symbolVal (Proxy @sym), (mimeRender (Proxy @a) x)) :)
         ((T.pack $ symbolVal (Proxy @sym), E.decodeUtf8 $ toHeader x) :)
    $ mkReq @t @m @sublayout @f xs

  getResp = getResp @t @m @sublayout @f

#if MIN_VERSION_servant(0,13,0)
-- TODO: Untested
instance (SupportsServantReflex t m,
          EndpointR t m sublayout f,
          KnownSymbol sym,
          ToHttpApiData a,
          Applicative f
         ) => EndpointR t m (Summary desc :> sublayout) f where

  type EInputs t m (Summary desc :> sublayout) f = EInputs t m sublayout f
  type EOutput t m (Summary desc :> sublayout) f = EOutput t m sublayout f

  mkReq   = mkReq @t @m @sublayout @f

  getResp = getResp @t @m @sublayout @f
#endif


#if MIN_VERSION_servant(0,13,0)
-- TODO: Untested
instance (SupportsServantReflex t m,
          EndpointR t m sublayout f,
          KnownSymbol sym,
          ToHttpApiData a,
          Applicative f
         ) => EndpointR t m (Description desc :> sublayout) f where

  type EInputs t m (Description desc :> sublayout) f = EInputs t m sublayout f
  type EOutput t m (Description desc :> sublayout) f = EOutput t m sublayout f

  mkReq   = mkReq @t @m @sublayout @f

  getResp = getResp @t @m @sublayout @f
#endif

instance (SupportsServantReflex t m,
          EndpointR t m sublayout f,
          KnownSymbol sym,
          ToHttpApiData a,
          Applicative f
         ) => EndpointR t m (IsSecure :> sublayout) f where


  type EInputs t m (IsSecure :> sublayout) f = EInputs t m sublayout f
  type EOutput t m (IsSecure :> sublayout) f = EOutput t m sublayout f

  mkReq   = mkReq @t @m @sublayout @f

  getResp = getResp @t @m @sublayout @f

instance (SupportsServantReflex t m,
          EndpointR t m sublayout f,
          KnownSymbol sym,
          ToHttpApiData a,
          Applicative f
         ) => EndpointR t m (Vault :> sublayout) f where


  type EInputs t m (Vault :> sublayout) f = EInputs t m sublayout f
  type EOutput t m (Vault :> sublayout) f = EOutput t m sublayout f

  mkReq   = mkReq @t @m @sublayout @f

  getResp = getResp @t @m @sublayout @f

instance (SupportsServantReflex t m,
          EndpointR t m sublayout f,
          Applicative f
         ) => EndpointR t m (BasicAuth realm usr :> sublayout) f where

  type EInputs t m (BasicAuth realm usr :> sublayout) f = BasicAuthData ': EInputs t m sublayout f
  type EOutput t m (BasicAuth realm usr :> sublayout) f = EOutput t m sublayout f

  mkReq (HCons x xs) =
    set (field @"reqRAuthData") (Just x) $ mkReq @t @m @sublayout @f xs

  getResp = getResp @t @m @sublayout @f


instance ToTuple (HList '[]) where
  type Tuple (HList '[]) = ()
  toTuple _ = ()
  fromTuple _ = HNil

instance ToTuple (HList '[a]) where
  type Tuple (HList '[a]) = a
  toTuple (HCons a HNil) = a
  fromTuple a = HCons a HNil

instance ToTuple (HList '[a,b]) where
  type Tuple (HList '[a,b]) = (a,b)
  toTuple (HCons a (HCons b HNil)) = (a,b)
  fromTuple (a,b) = HCons a (HCons b HNil)

instance ToTuple (HList '[a,b,c]) where
  type Tuple (HList '[a,b,c]) = (a,b,c)
  toTuple (HCons a (HCons b (HCons c HNil))) = (a,b,c)
  fromTuple (a,b,c) = HCons a (HCons b (HCons c HNil))

type MyAPI = Header "hi" Int :> Capture "hello" Int :> Capture "hello2" Bool :> Get '[JSON] (Headers '[Header "hi" Int] Int)
        :<|> Get '[JSON] Bool

type MyAPI2 = Raw


m :: forall t m.MonadWidget t m => m ()
m = do
  let (a :<|> b) = clientR (Proxy @MyAPI) (Proxy :: Proxy m) (Proxy :: Proxy t)
                           (Proxy @[]) undefined
  btn <- button "Hello"
  resA <- a (fmap (:[]) ((2, 5,True) <$ btn))
  resB <- b (fmap (:[]) (() <$ btn))
  display =<< holdDyn "waiting" (leftmost [show <$> resB ])
                                 -- [show <$> resA
                                 -- , show <$> resB
                                 -- ])

  let rawR = clientR (Proxy @MyAPI2) (Proxy @m) (Proxy @t) (Proxy @[]) undefined
  return ()

data ReqR = ReqR
  { reqRMethod      :: T.Text
  , reqRPathParts   :: [T.Text]
  , reqRParams      :: [(T.Text, QueryPart)]
  , reqRBody        :: Maybe (BL.ByteString, T.Text)
  , reqRHeaders     :: [(T.Text, T.Text)]
  , reqRRespHeaders :: XhrResponseHeaders
  , reqRAuthData    :: Maybe BasicAuthData
  } deriving (Generic)

instance Show ReqR where
  show (ReqR m pp ps b hs hs' a) = concat $ L.intersperse "\n" [
    "ReqR {"
    , ("reqRMethod = " <> show m)
    , ("reqRPathParts = " <> show pp)
    , ("reqRParams = " <> show ps)
    , ("reqRBody = " <> show b)
    , ("reqRHeaders = " <> show hs)
    , ("reqRRespHeaders = " <> show hs')
    , ("reqRAuthData = " <> maybe "Nothing" (const "Just <<redacted>>") a)
    ]

emptyReqR :: T.Text -> ReqR
emptyReqR method = ReqR method [] [] Nothing  [] (OnlyHeaders mempty) Nothing

data QueryPart = QueryPartParam  (Maybe Text)
               | QueryPartParams [Text]
               | QueryPartFlag   Bool
               deriving (Show)

mkXhrRequest :: BaseUrl -> ReqR -> XhrRequest T.Text
mkXhrRequest reqHost req =
  let path = T.intercalate "/" $ reqRPathParts req

      queryPartString :: (Text, QueryPart) -> Maybe Text
      queryPartString (pName, qp) = case qp of

        QueryPartParam Nothing  -> Nothing
        QueryPartParam (Just a) -> Just (pName <> "=" <> escape a)

        QueryPartParams ps      -> Just . T.intercalate "&"
                                        $ fmap (\p -> pName <> "=" <> escape p)
                                        ps

        QueryPartFlag True     -> Just pName
        QueryPartFlag False    -> Nothing

      (</>) :: Text -> Text -> Text
      x </> y | ("/" `T.isSuffixOf` x) || ("/" `T.isPrefixOf` y) = x <> y
              | otherwise = x <> "/" <> y

      queryString = T.intercalate "&" . catMaybes . map queryPartString $ reqRParams req
      url  = showBaseUrl reqHost </> path <> if T.null queryString then "" else (T.cons '?' queryString)

      (headers, body) =
        let headers0 = M.fromList $ reqRHeaders req
        in case reqRBody req of
             Nothing      -> (headers0, "")
             Just (rb,ct) -> (M.insert "Content-Type" ct headers0,
                              E.decodeUtf8 $ BL.toStrict rb)

      xhrReqConfig = def
        { _xhrRequestConfig_headers = headers
        , _xhrRequestConfig_user = E.decodeUtf8 . basicAuthUsername <$> reqRAuthData req
        , _xhrRequestConfig_password = E.decodeUtf8 . basicAuthPassword <$> reqRAuthData req
        , _xhrRequestConfig_responseType = Just XhrResponseType_ArrayBuffer
        , _xhrRequestConfig_sendData = body
        , _xhrRequestConfig_responseHeaders = reqRRespHeaders req
        , _xhrRequestConfig_withCredentials = False
        }
      xhrReq = XhrRequest (reqRMethod req) url xhrReqConfig
  in xhrReq

transformExample :: MonadWidget t m => ((Int, Char) -> Performable m Bool) -> Event t (Int, Char) -> m (Event t Bool)
transformExample f = \triggers -> performEvent (f <$> triggers)
-- transformExample = undefined -- let x = performEvent :: _ in undefined

transform :: MonadWidget t m => forall a. (inp -> IO outp) -> (Event t inp -> m (Event t outp))
transform = undefined
