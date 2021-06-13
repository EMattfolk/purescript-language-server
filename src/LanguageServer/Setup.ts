import { IConnection, createConnection,InitializeParams, IPCMessageReader, IPCMessageWriter, TextDocuments, Location, Hover, TextDocumentSyncKind, CodeActionKind } from 'vscode-languageserver';
import { TextDocument } from 'vscode-languageserver-textdocument';
exports.initConnection = (commands: string[]) => (cb: (arg: {params: InitializeParams, conn: IConnection}) => () => void) => (): IConnection => {
    const conn = createConnection();
    conn.listen();
    
    conn.onInitialize((params) => {
        conn.console.info(JSON.stringify(params));
        cb({
            params,
            conn
        })();

        return {
            capabilities: {
                // Tell the client that the server works in FULL text document sync mode
                textDocumentSync: TextDocumentSyncKind.Full,
                // Tell the client that the server support code complete
                completionProvider: {
                    resolveProvider: false,
                    triggerCharacters: ["."]
                },
                hoverProvider: true,
                definitionProvider: true,
                workspaceSymbolProvider: true,
                documentSymbolProvider: true,
                codeActionProvider: { codeActionKinds: [ CodeActionKind.Empty, CodeActionKind.SourceOrganizeImports, "source.sortImports", CodeActionKind.SourceFixAll, CodeActionKind.Source ] },
                executeCommandProvider: (params.initializationOptions||{}).executeCommandProvider === false
                    ? undefined : {
                        commands
                    },
                referencesProvider: true,
                foldingRangeProvider: true,
                documentFormattingProvider: true
            }
        };
    });
    return conn;
}

exports.initDocumentStore = (conn : IConnection) => () => {
    const documents: TextDocuments<TextDocument> = new TextDocuments(TextDocument);
    documents.listen(conn);
    return documents;
}

exports.getConfigurationImpl = (conn : IConnection) => () =>
    conn.workspace.getConfiguration("purescript").then(config => {
        return { purescript: config };
    });
