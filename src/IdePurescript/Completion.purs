module IdePurescript.Completion where

import Prelude

import Control.Alt ((<|>))
import Data.Array (concatMap, filter, foldl, head, intersect, snoc, sortBy, sortWith, (:))
import Data.Array as Array
import Data.Either (Either)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe, fromMaybe', isJust)
import Data.Set as Set
import Data.String (Pattern(..), contains, indexOf, length, stripSuffix, take)
import Data.String.Regex (Regex, regex)
import Data.String.Regex.Flags (global, noFlags)
import Data.String.Utils (endsWith, startsWith)
import Data.Traversable (any, traverse)
import Data.Tuple (Tuple(..))
import Data.Tuple as Tuple
import Effect.Aff (Aff)
import IdePurescript.PscIde (getAvailableModules, getCompletion')
import IdePurescript.PscIdeServer (Notify)
import IdePurescript.Regex (match')
import IdePurescript.Tokens (containsArrow, identPart, modulePart, moduleRegex, startsWithCapitalLetter)
import PscIde.Command (CompletionOptions(..), DeclarationType(..), Namespace, TypeInfo(..))
import PscIde.Command as C

type ModuleInfo =
  { modules :: Array String
  , getQualifiedModule :: String -> Array String
  , mainModule :: Maybe String
  , importedModules :: Array String
  , openModules :: Array String
  , candidateModules :: String -> Array String
  }

data SuggestionType
  = Module
  | Type
  | DCtor
  | Function
  | Value
  | Kind

instance showSuggestionType :: Show SuggestionType where
  show Module = "Module"
  show Type = "Type"
  show DCtor = "DCtor"
  show Function = "Function"
  show Value = "Value"
  show Kind = "Kind"

parseSuggestionType :: String -> Maybe SuggestionType
parseSuggestionType = case _ of
  "Module" -> Just Module
  "Type" -> Just Type
  "DCtor" -> Just DCtor
  "Function" -> Just Function
  "Value" -> Just Value
  _ -> Nothing

explicitImportRegex :: Either String Regex
explicitImportRegex = regex
  ("""^import\s+""" <> modulePart <> """\s+\([^)]*?""" <> identPart <> "$")
  noFlags

getModuleSuggestions :: Int -> String -> Aff (Array String)
getModuleSuggestions port prefix = do
  list <- getAvailableModules port
  pure $ filter (\m -> indexOf (Pattern prefix) m == Just 0) list

data SuggestionResult
  = ModuleSuggestion
      { text :: String, suggestType :: SuggestionType, prefix :: String }
  | IdentSuggestion
      { origMod :: String
      , exportMod :: String
      , exportedFrom :: Array String
      , identifier :: String
      , qualifier :: Maybe String
      , valueType :: String
      , suggestType :: SuggestionType
      , namespace :: Maybe C.Namespace
      , prefix :: String
      , documentation :: Maybe String
      }
  | QualifierSuggestion { text :: String, mod :: String }

getSuggestions ::
  Notify ->
  Int ->
  { line :: String
  , moduleInfo :: ModuleInfo
  , qualifiers :: Array { qualifier :: String, moduleName :: String }
  , groupCompletions :: Boolean
  , maxResults :: Maybe Int
  , preferredModules :: Array String
  } ->
  Aff { results :: Array SuggestionResult, isIncomplete :: Boolean }
getSuggestions
  _notify
  port
  { line
  , moduleInfo:
      { modules
      , getQualifiedModule
      , mainModule
      , importedModules
      , openModules: _
      , candidateModules
      }
  , qualifiers
  , maxResults
  , groupCompletions
  , preferredModules
  } =
  if moduleExplicit then
    case match' explicitImportRegex line of
      Just [ Just _, Just mod, Just token ] -> do
        let
          cc ns = Tuple ns <$> getCompletion' Nothing
            [ C.PrefixFilter token, C.NamespaceFilter [ ns ] ]
            port
            mainModule
            Nothing
            [ mod ]
            getQualifiedModule
            opts
        completions <- traverse cc [ C.NSValue, C.NSType ]
        pure $ complete $ concatMap
          (\(Tuple n cs) -> result Nothing token (Just n) <$> cs)
          completions
      _ -> pure $ complete []
  else
    case parsed of
      Just { mod, token } ->
        if moduleCompletion then do
          let prefix = getModuleName (fromMaybe "" mod) token
          completions <- getModuleSuggestions port prefix
          pure $ complete $ map (modResult prefix) completions
        else do
          let
            cc ns = (map (Tuple ns)) <$> getCompletion' Nothing
              [ C.PrefixFilter token, C.NamespaceFilter [ ns ] ]
              port
              mainModule
              mod
              ("Prim" : modules)
              getQualifiedModule
              opts
          completions :: Array (Array (Tuple Namespace TypeInfo)) <- traverse cc
            [ C.NSValue, C.NSType ]
          let
            isIncomplete = any (\list -> Just (Array.length list) == maxResults)
              completions
            completions' = simplifyImportChoice Tuple.snd $ Array.concat
              completions
            results =
              matchingQualifiers mod token
                <>
                  ( (\(Tuple n c) -> result mod token (Just n) c) <$>
                      (takeExisting mod token $ completions')
                  )
          pure { results, isIncomplete }
      Nothing -> pure $ complete []
  where
  complete results = { results, isIncomplete: false }
  opts = CompletionOptions { maxResults, groupReexports: groupCompletions }

  matchingQualifiers (Just _) _ = []
  matchingQualifiers Nothing token = convQ <$> Array.filter
    (\{ qualifier } -> indexOf (Pattern token) qualifier == Just 0)
    qualifiers
    where
    convQ { qualifier, moduleName } = QualifierSuggestion
      { text: qualifier, mod: moduleName }

  getModuleName "" token = token
  getModuleName mod token = mod <> "." <> token

  isImport = indexOf (Pattern "import ") line == Just 0
  hasBracket = indexOf (Pattern "(") line /= Nothing
  moduleCompletion = isImport && not hasBracket
  moduleExplicit = isImport && hasBracket

  parsed = case match' moduleRegex line of
    Just [ Just _, mod, tok ]
      | mod /= Nothing || tok /= Nothing ->
          Just { mod, token: fromMaybe "" tok }
    _ -> Nothing

  takeExisting (Just _) _token completions = completions
  takeExisting Nothing _token completions =
    Array.filter filterCompletion completions
    where
    ident (Tuple _ (TypeInfo { identifier })) = identifier
    candidateModules' = Map.fromFoldable $
      (\x -> Tuple x (Set.fromFoldable $ candidateModules x)) <$> Array.nub
        (ident <$> completions)

    -- for each ident, the modules it may be imported from for some completion
    existingIdents =
      Map.filter (not <<< Set.isEmpty)
        $ Map.fromFoldableWith Set.union
        $ map
            ( \(Tuple _ (TypeInfo { identifier, module', exportedFrom })) ->
                let
                  exportedModules = Set.fromFoldable $ module' : exportedFrom
                  candidates = fromMaybe Set.empty
                    (Map.lookup identifier candidateModules')
                  matches = candidates `Set.intersection` exportedModules
                in
                  Tuple identifier matches
            )
            completions
    -- Tuple x $ Set.fromFoldable $ candidateModules x) completions
    -- filter each completion according to the modules it came from compared to the modules we might have already imported from, in this or some other completion
    filterCompletion
      ( Tuple ns
          (TypeInfo { identifier, module', exportedFrom, declarationType })
      ) =
      let
        resolvedNS = (declarationType >>= declarationTypeToNamespace) <|> Just
          ns
        isDctor = case resolvedNS of
          Just C.NSValue -> startsWithCapitalLetter identifier
          _ -> false
      in
        case Map.lookup identifier existingIdents of
          -- This ident isn't imported, or we cut off completions before the imported result came back, show all completions
          Nothing -> true
          -- Don't have explicit import information on dctors
          _ | isDctor -> true
          -- This ident is imported already, only show completions from the module it could have come from
          Just candidateMods ->
            let
              exportedModules = Set.fromFoldable $ module' : exportedFrom
            in
              not $ Set.isEmpty $ candidateMods `Set.intersection`
                exportedModules

  modResult prefix moduleName = ModuleSuggestion
    { text: moduleName, suggestType: Module, prefix }
  result
    qualifier
    prefix
    ns
    ( TypeInfo
        { type'
        , identifier
        , module': origMod
        , exportedFrom
        , documentation
        , declarationType
        }
    ) =
    IdentSuggestion
      { origMod
      , exportMod
      , identifier
      , qualifier
      , suggestType
      , prefix
      , valueType: type'
      , namespace: ns
      , exportedFrom
      , documentation
      }
    where
    -- use the declaration type of the result if available, or the ns we filtered the request by if we're doing that
    resolvedNS = (declarationType >>= declarationTypeToNamespace) <|> ns
    suggestType =
      case resolvedNS of
        Just C.NSKind -> Kind
        Just C.NSType -> Type
        Just C.NSValue
          | startsWithCapitalLetter identifier -> DCtor
          | containsArrow type' -> Function
        Just C.NSValue -> Value
        Nothing -> Value

    -- Strategies for picking the re-export to choose
    -- 1. User configuration of preferred modules (ordered list)
    -- 2. Existing imports
    -- 3. Re-export from a prefix named module (e.g. Foo.Bar.Baz reexported from Foo.Bar) shortest first
    -- 4. Original module (if none of the previous rules apply, there are no re-exports, or either grouping
    --    is disabled or compiler version does not support it)
    exportMod = fromMaybe origMod
      (preferredModule <|> existingModule <|> prefixModule)
    existingModule = head $ intersect importedModules exportedFrom
    preferredModule = head $ intersect preferredModules exportedFrom
    prefixModule =
      head
        $ sortBy (\a b -> length a `compare` length b)
        $ filter (\m -> startsWith (m <> ".") origMod) exportedFrom

declarationTypeToNamespace :: DeclarationType -> Maybe Namespace
declarationTypeToNamespace = case _ of -- Should this live somewhere else?
  DeclValue -> Just C.NSValue
  DeclType -> Just C.NSType
  DeclTypeSynonym -> Just C.NSType
  DeclDataConstructor -> Just C.NSValue
  DeclTypeClass -> Just C.NSType
  DeclValueOperator -> Just C.NSValue
  DeclTypeOperator -> Just C.NSType
  DeclModule -> Nothing

-- | Removes choices that are not worth the brain-cycles to make.
-- | 
-- | If there are two suggestions to 
-- |   1. import Something(..) and
-- |   2. import Something 
-- | We only import Something(..) because it can be automatically simplified
-- | with an optimise import action
simplifyImportChoice :: forall a. (a -> TypeInfo) -> Array a -> Array a
simplifyImportChoice f before = foldl go [] before
  where
  go acc info =
    if
      isType (f info) && any (f >>> isTheSameButDataConstructor (f info)) before then
      acc
    else
      snoc acc info

  isType = case _ of
    TypeInfo { declarationType: Just DeclType } -> true
    _ -> false

  isDataConstructor = case _ of
    TypeInfo { declarationType: Just DeclDataConstructor } -> true
    TypeInfo { declarationType: Just DeclValue, identifier }
      | startsWithCapitalLetter identifier -> true
    _ -> false

  -- We could have data Foo = X and data Bar = Foo, check the dctor Foo has some type that could conceivably be a dctor for Foo
  -- i.e. is a (possibly nullary) function to Foo
  dctorMatchesType typeName (TypeInfo { type' }) =
    endsWith ("-> " <> typeName) type'
      || endsWith ("→ " <> typeName) type'
      || typeName == type'

  isTheSameButDataConstructor (TypeInfo ti1) info2@(TypeInfo ti2) =
    ti1.identifier
      == ti2.identifier
      && ti1.module'
        == ti2.module'
      && isDataConstructor info2
      && dctorMatchesType ti1.identifier info2

partsRegex :: Either String Regex
partsRegex =
  regex
    ("""[A-Z][a-z]*""")
    global

sortImportChoices word qualifier =
  let
    score (TypeInfo { type', identifier, module', declarationType }) =
      case qualifier, word == identifier of
        Just qual, true -> -- Correct name, we need to figure out which module we want.
          [ \_ -> qual == module' -- Perfect match.
          , \_ -> module' # stripSuffix (Pattern qual) # isJust -- Module ends with qual
          , \_ -> module' # contains (Pattern qual) -- Module contains qual
          ]
            # Array.findIndex (\f -> f unit)
            # fromMaybe'
                ( \_ ->
                    let
                      -- Try splitting the qualifier into parts "AbaBab" -> ["A", "B"]
                      -- and check how many letters are in the module. More is
                      -- assumed to be better.
                      l =
                        qual
                          # match' partsRegex
                          # fromMaybe []
                          <#> fromMaybe "§"
                          # filter (\part -> module' # contains (Pattern (take 1 part)))
                          # Array.length
                    in
                    9998 - l
                )
        _, _ -> 9999 -- Incorrect name, lets just leave it.
  in
  sortWith score
