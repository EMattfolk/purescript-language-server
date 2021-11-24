module LanguageServer.IdePurescript.FoldingRanges
  ( getFoldingRanges
  )
  where

import Prelude

import Data.Array as Array
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Nullable (Nullable)
import Data.Nullable as Nullable
import Effect.Aff (Aff)
import Effect.Class (liftEffect)
import IdePurescript.PscIdeServer (ErrorLevel(..), Notify)
import LanguageServer.IdePurescript.Types (ServerState(..))
import LanguageServer.IdePurescript.Util (maybeParseResult)
import LanguageServer.Protocol.Handlers (FoldingRangesParams)
import LanguageServer.Protocol.Types (DocumentStore, FoldingRange(..), Settings, TextDocumentIdentifier(..))
import PscIde.Command (Position)
import PureScript.CST.Range (class RangeOf, rangeOf)
import PureScript.CST.Types (Module(..), ModuleBody(..), ModuleHeader(..), SourceRange)

getFoldingRanges :: Notify -> DocumentStore -> Settings -> ServerState -> FoldingRangesParams -> Aff (Array FoldingRange)
getFoldingRanges notify _docs _ (ServerState { parsedModules }) { textDocument: TextDocumentIdentifier { uri } } =
  case Map.lookup uri parsedModules of
    Just { parsed } -> 
      pure $ maybeParseResult [] getRanges parsed
    Nothing -> do
      liftEffect $ notify Warning $ "getFoldingRanges - no parsed CST for " <> show uri
      pure []

getRanges :: forall a. RangeOf a => Module a -> Array FoldingRange
getRanges (Module { header: ModuleHeader { imports }, body: ModuleBody { decls } }) =
  let
    importRanges = case Array.head imports, Array.last imports of
      Just a, Just b ->
        [ makeRange (Nullable.notNull "imports") (rangeOf a).start (rangeOf b).end ]
      _, _ -> []
    bodyRanges = makeRange' <<< rangeOf <$> decls
  in
    importRanges <> bodyRanges

makeRange' :: SourceRange -> FoldingRange
makeRange' range = makeRange Nullable.null range.start range.end

makeRange ∷ Nullable String -> Position -> Position -> FoldingRange
makeRange kind startPos endPos =
  FoldingRange
    { startLine: startPos.line
    , startCharacter: Nullable.notNull startPos.column
    , endLine: endPos.line
    , endCharacter: Nullable.notNull endPos.column
    , kind
    }
