module NoUnused.CustomTypeConstructorArgs exposing (rule)

{-|

@docs rule

-}

import Dict exposing (Dict)
import Elm.Module
import Elm.Project
import Elm.Syntax.Declaration as Declaration exposing (Declaration)
import Elm.Syntax.Exposing as Exposing exposing (Exposing)
import Elm.Syntax.Expression as Expression exposing (Expression)
import Elm.Syntax.Module as Module exposing (Module)
import Elm.Syntax.ModuleName exposing (ModuleName)
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern as Pattern exposing (Pattern)
import Elm.Syntax.Range exposing (Range)
import Review.Rule as Rule exposing (Error, Rule)
import Scope
import Set exposing (Set)


{-| Reports arguments of custom type constructors that are never used.

    config =
        [ NoUnused.CustomTypeConstructorArgs.rule
        ]

Custom type constructors can contain data that is never extracted out of the constructor.
This rule will warn arguments that are always pattern matched using a wildcard (`_`).

For package projects, custom types whose constructors are exposed as part of the package API are not reported.


## Fail

    type CustomType
      = CustomType Used Unused

    case customType of
      CustomType value _ -> value


## Success

    type CustomType
      = CustomType Used Unused

    case customType of
      CustomType value maybeUsed -> value


## When not to enable this rule?

If you like giving names to all arguments when pattern matching, then this rule will not found many problems.
This rule will work well when enabled along with [`NoUnused.Patterns`](./NoUnused-Patterns).


## Try it out

You can try this rule out by running the following command:

```bash
elm-review --template jfmengels/elm-review-unused/example --rules NoUnused.CustomTypeConstructorArgs
```

-}
rule : Rule
rule =
    Rule.newProjectRuleSchema "NoUnused.CustomTypeConstructorArgs" initialProjectContext
        |> Scope.addProjectVisitors
        |> Rule.withElmJsonProjectVisitor elmJsonVisitor
        |> Rule.withModuleVisitor moduleVisitor
        |> Rule.withModuleContext
            { fromProjectToModule = fromProjectToModule
            , fromModuleToProject = fromModuleToProject
            , foldProjectContexts = foldProjectContexts
            }
        |> Rule.withFinalProjectEvaluation finalEvaluation
        |> Rule.fromProjectRuleSchema


type alias ProjectContext =
    { scope : Scope.ProjectContext
    , exposedModules : Set ModuleName
    , customTypeArgs :
        Dict ModuleName
            { moduleKey : Rule.ModuleKey
            , args : Dict String (List Range)
            }
    , usedArguments : Dict ( ModuleName, String ) (Set Int)
    }


type alias ModuleContext =
    { scope : Scope.ModuleContext
    , isModuleExposed : Bool
    , exposed : Exposing
    , customTypeArgs : Dict String (Dict String (List Range))
    , usedArguments : Dict ( ModuleName, String ) (Set Int)
    }


moduleVisitor : Rule.ModuleRuleSchema {} ModuleContext -> Rule.ModuleRuleSchema { hasAtLeastOneVisitor : () } ModuleContext
moduleVisitor schema =
    schema
        |> Rule.withModuleDefinitionVisitor moduleDefinitionVisitor
        |> Rule.withDeclarationListVisitor declarationListVisitor
        |> Rule.withDeclarationEnterVisitor declarationVisitor
        |> Rule.withExpressionEnterVisitor expressionVisitor


elmJsonVisitor : Maybe { a | project : Elm.Project.Project } -> ProjectContext -> ( List nothing, ProjectContext )
elmJsonVisitor maybeEProject projectContext =
    case Maybe.map .project maybeEProject of
        Just (Elm.Project.Package package) ->
            let
                exposedModules : List Elm.Module.Name
                exposedModules =
                    case package.exposed of
                        Elm.Project.ExposedList list ->
                            list

                        Elm.Project.ExposedDict list ->
                            List.concatMap Tuple.second list

                exposedNames : Set ModuleName
                exposedNames =
                    exposedModules
                        |> List.map (Elm.Module.toString >> String.split ".")
                        |> Set.fromList
            in
            ( [], { projectContext | exposedModules = exposedNames } )

        _ ->
            ( [], projectContext )


initialProjectContext : ProjectContext
initialProjectContext =
    { scope = Scope.initialProjectContext
    , exposedModules = Set.empty
    , customTypeArgs = Dict.empty
    , usedArguments = Dict.empty
    }


fromProjectToModule : Rule.ModuleKey -> Node ModuleName -> ProjectContext -> ModuleContext
fromProjectToModule _ moduleName projectContext =
    { scope = Scope.fromProjectToModule projectContext.scope
    , isModuleExposed = Set.member (Node.value moduleName) projectContext.exposedModules
    , exposed = Exposing.Explicit []
    , customTypeArgs = Dict.empty
    , usedArguments = Dict.empty
    }


fromModuleToProject : Rule.ModuleKey -> Node ModuleName -> ModuleContext -> ProjectContext
fromModuleToProject moduleKey moduleName moduleContext =
    { scope = Scope.fromModuleToProject moduleName moduleContext.scope
    , exposedModules = Set.empty
    , customTypeArgs =
        Dict.singleton
            (Node.value moduleName)
            { moduleKey = moduleKey
            , args = getNonExposedCustomTypes moduleContext
            }
    , usedArguments =
        Dict.foldl
            (\( moduleNameForType, name ) value dict ->
                case moduleNameForType of
                    [] ->
                        Dict.insert ( Node.value moduleName, name ) value dict

                    _ ->
                        Dict.insert ( moduleNameForType, name ) value dict
            )
            Dict.empty
            moduleContext.usedArguments
    }


getNonExposedCustomTypes : ModuleContext -> Dict String (List Range)
getNonExposedCustomTypes moduleContext =
    if moduleContext.isModuleExposed then
        case moduleContext.exposed of
            Exposing.All _ ->
                Dict.empty

            Exposing.Explicit list ->
                let
                    exposedCustomTypes : Set String
                    exposedCustomTypes =
                        list
                            |> List.filterMap
                                (\exposed ->
                                    case Node.value exposed of
                                        Exposing.TypeExpose { name, open } ->
                                            case open of
                                                Just _ ->
                                                    Just name

                                                Nothing ->
                                                    Nothing

                                        _ ->
                                            Nothing
                                )
                            |> Set.fromList
                in
                moduleContext.customTypeArgs
                    |> Dict.filter (\typeName _ -> not <| Set.member typeName exposedCustomTypes)
                    |> Dict.values
                    |> List.foldl Dict.union Dict.empty

    else
        moduleContext.customTypeArgs
            |> Dict.values
            |> List.foldl Dict.union Dict.empty


foldProjectContexts : ProjectContext -> ProjectContext -> ProjectContext
foldProjectContexts newContext previousContext =
    { scope = Scope.foldProjectContexts newContext.scope previousContext.scope
    , exposedModules = previousContext.exposedModules
    , customTypeArgs =
        Dict.union
            newContext.customTypeArgs
            previousContext.customTypeArgs
    , usedArguments =
        Dict.merge
            Dict.insert
            (\key newSet prevSet dict -> Dict.insert key (Set.union newSet prevSet) dict)
            Dict.insert
            newContext.usedArguments
            previousContext.usedArguments
            Dict.empty
    }



-- MODULE DEFINITION VISITOR


moduleDefinitionVisitor : Node Module -> ModuleContext -> ( List nothing, ModuleContext )
moduleDefinitionVisitor node moduleContext =
    ( [], { moduleContext | exposed = Module.exposingList (Node.value node) } )



-- DECLARATION LIST VISITOR


declarationListVisitor : List (Node Declaration) -> ModuleContext -> ( List nothing, ModuleContext )
declarationListVisitor nodes context =
    let
        customTypeArgs : List ( String, Dict String (List Range) )
        customTypeArgs =
            List.filterMap collectCustomType nodes
    in
    ( [], { context | customTypeArgs = Dict.fromList customTypeArgs } )


collectCustomType : Node Declaration -> Maybe ( String, Dict String (List Range) )
collectCustomType node =
    case Node.value node of
        Declaration.CustomTypeDeclaration typeDeclaration ->
            let
                customTypeConstructors : List ( String, List Range )
                customTypeConstructors =
                    typeDeclaration.constructors
                        |> List.map (Node.value >> (\{ name, arguments } -> ( Node.value name, List.map Node.range arguments )))
            in
            Just ( Node.value typeDeclaration.name, Dict.fromList customTypeConstructors )

        _ ->
            Nothing



-- DECLARATION VISITOR


declarationVisitor : Node Declaration -> ModuleContext -> ( List nothing, ModuleContext )
declarationVisitor node context =
    -- TODO Move to declaration list visitor, or the other way around
    case Node.value node of
        Declaration.FunctionDeclaration function ->
            ( []
            , { context
                | usedArguments =
                    registerUsedPatterns
                        (collectUsedPatternsFromFunctionDeclaration context function)
                        context.usedArguments
              }
            )

        _ ->
            ( [], context )


collectUsedPatternsFromFunctionDeclaration : ModuleContext -> Expression.Function -> List ( ( ModuleName, String ), Set Int )
collectUsedPatternsFromFunctionDeclaration context { declaration } =
    (Node.value declaration).arguments
        |> List.concatMap (collectUsedCustomTypeArgs context.scope)



-- EXPRESSION VISITOR


expressionVisitor : Node Expression -> ModuleContext -> ( List nothing, ModuleContext )
expressionVisitor node context =
    case Node.value node of
        Expression.CaseExpression { cases } ->
            let
                usedArguments : List ( ( ModuleName, String ), Set Int )
                usedArguments =
                    cases
                        |> List.concatMap (Tuple.first >> collectUsedCustomTypeArgs context.scope)
            in
            ( [], { context | usedArguments = registerUsedPatterns usedArguments context.usedArguments } )

        Expression.LetExpression { declarations } ->
            let
                usedArguments : List ( ( ModuleName, String ), Set Int )
                usedArguments =
                    List.concatMap
                        (\declaration ->
                            case Node.value declaration of
                                Expression.LetDestructuring pattern _ ->
                                    collectUsedCustomTypeArgs context.scope pattern

                                Expression.LetFunction function ->
                                    collectUsedPatternsFromFunctionDeclaration context function
                        )
                        declarations
            in
            ( [], { context | usedArguments = registerUsedPatterns usedArguments context.usedArguments } )

        Expression.LambdaExpression { args } ->
            ( []
            , { context
                | usedArguments =
                    registerUsedPatterns
                        (List.concatMap (collectUsedCustomTypeArgs context.scope) args)
                        context.usedArguments
              }
            )

        _ ->
            ( [], context )


registerUsedPatterns : List ( ( ModuleName, String ), Set Int ) -> Dict ( ModuleName, String ) (Set Int) -> Dict ( ModuleName, String ) (Set Int)
registerUsedPatterns newUsedArguments previouslyUsedArguments =
    List.foldl
        (\( key, usedPositions ) acc ->
            let
                previouslyUsedPositions : Set Int
                previouslyUsedPositions =
                    Dict.get key acc
                        |> Maybe.withDefault Set.empty
            in
            Dict.insert key (Set.union previouslyUsedPositions usedPositions) acc
        )
        previouslyUsedArguments
        newUsedArguments


collectUsedCustomTypeArgs : Scope.ModuleContext -> Node Pattern -> List ( ( ModuleName, String ), Set Int )
collectUsedCustomTypeArgs scope (Node _ pattern) =
    case pattern of
        Pattern.NamedPattern { moduleName, name } args ->
            let
                usedPositions : Set Int
                usedPositions =
                    args
                        |> List.indexedMap Tuple.pair
                        |> List.filter (\( _, subPattern ) -> not <| isWildcard subPattern)
                        |> List.map Tuple.first
                        |> Set.fromList
            in
            [ ( ( Scope.moduleNameForValue scope name moduleName, name ), usedPositions ) ]
                ++ List.concatMap (collectUsedCustomTypeArgs scope) args

        Pattern.TuplePattern patterns ->
            List.concatMap (collectUsedCustomTypeArgs scope) patterns

        Pattern.ListPattern patterns ->
            List.concatMap (collectUsedCustomTypeArgs scope) patterns

        Pattern.UnConsPattern left right ->
            List.concatMap (collectUsedCustomTypeArgs scope) [ left, right ]

        Pattern.ParenthesizedPattern subPattern ->
            collectUsedCustomTypeArgs scope subPattern

        Pattern.AsPattern subPattern _ ->
            collectUsedCustomTypeArgs scope subPattern

        _ ->
            []


isWildcard : Node Pattern -> Bool
isWildcard node =
    case Node.value node of
        Pattern.AllPattern ->
            True

        Pattern.ParenthesizedPattern pattern ->
            isWildcard pattern

        _ ->
            False



-- FINAL EVALUATION


finalEvaluation : ProjectContext -> List (Error { useErrorForModule : () })
finalEvaluation context =
    context.customTypeArgs
        |> Dict.toList
        |> List.concatMap
            (\( moduleName, { moduleKey, args } ) ->
                args
                    |> Dict.toList
                    |> List.concatMap
                        (\( name, ranges ) ->
                            case Dict.get ( moduleName, name ) context.usedArguments of
                                Just usedArgumentPositions ->
                                    ranges
                                        |> List.indexedMap Tuple.pair
                                        |> List.filter (\( index, _ ) -> not <| Set.member index usedArgumentPositions)
                                        |> List.map (Tuple.second >> error moduleKey)

                                Nothing ->
                                    List.map (error moduleKey) ranges
                        )
            )


error : Rule.ModuleKey -> Range -> Error anywhere
error moduleKey range =
    Rule.errorForModule moduleKey
        { message = "Argument is never extracted and therefore never used."
        , details =
            [ "This argument is never used. You should either use it somewhere, or remove it at the location I pointed at."
            ]
        }
        range
