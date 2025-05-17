const Handler = @This();

const std = @import("std");

const lsp = @import("lsp");
const types = lsp.types;

const Errors = @import("errors.zig");
const Error = Errors.Error;

ptr: *anyopaque,
vtable: *const VTable,
pub const VTable = struct {
    hover: ?*const fn(*anyopaque, types.HoverParams) Error!?types.Hover = null,
    willSaveWaitUntil: ?*const fn(*anyopaque, types.WillSaveTextDocumentParams) Error!?[]types.TextEdit = null,
    semanticTokensFull: ?*const fn(*anyopaque, types.SemanticTokensParams) Error!?types.SemanticTokens = null,
    semanticTokensRange: ?*const fn(*anyopaque, types.SemanticTokensRangeParams) Error!?types.SemanticTokens = null,
    completion: ?*const fn(*anyopaque, types.CompletionParams) Error!lsp.ResultType("textDocument/completion") = null,
    signatureHelp: ?*const fn(*anyopaque, types.SignatureHelpParams) Error!?types.SignatureHelp = null,
    gotoDefinition: ?*const fn(*anyopaque, types.DefinitionParams) Error!lsp.ResultType("textDocument/definition") = null,
    gotoTypeDefinition: ?*const fn(*anyopaque, types.TypeDefinitionParams) Error!lsp.ResultType("textDocument/typeDefinition") = null,
    gotoImplementation: ?*const fn(*anyopaque, types.ImplementationParams) Error!lsp.ResultType("textDocument/implementation") = null,
    gotoDeclaration: ?*const fn(*anyopaque, types.DeclarationParams) Error!lsp.ResultType("textDocument/declaration") = null,
    documentSymbols: ?*const fn(*anyopaque, types.DocumentSymbolParams) Error!lsp.ResultType("textDocument/documentSymbol") = null,
    formatting: ?*const fn(*anyopaque, types.DocumentFormattingParams) Error!?[]types.TextEdit = null,
    rename: ?*const fn(*anyopaque, types.RenameParams) Error!?types.WorkspaceEdit = null,
    references: ?*const fn(*anyopaque, types.ReferenceParams) Error!?[]types.Location = null,
    documentHighlight: ?*const fn(*anyopaque, types.DocumentHighlightParams) Error!?[]types.DocumentHighlight = null,
    inlayHint: ?*const fn(*anyopaque, types.InlayHintParams) Error!?[]types.InlayHint = null,
    codeAction: ?*const fn(*anyopaque, types.CodeActionParams) Error!lsp.ResultType("textDocument/codeAction") = null,
    foldingRange: ?*const fn(*anyopaque, types.FoldingRangeParams) Error!?[]types.FoldingRange = null,
    selectionRange: ?*const fn(*anyopaque, types.SelectionRangeParams) Error!?[]types.SelectionRange = null,
};

fn nullOrImpl(self: Handler, params: anytype, returns: type, func: anytype) returns {
    if (func == null) {
        return null;
    }
    return func.?(self.ptr, params);
}

pub fn hover(self: Handler, params: types.HoverParams) Error!?types.Hover {
    return self.nullOrImpl(params, Error!?types.Hover, self.vtable.hover);
}

pub fn willSaveWaitUntil(self: Handler, params: types.WillSaveTextDocumentParams) Error!?[]types.TextEdit {
    return self.nullOrImpl(params, Error!?[]types.TextEdit, self.vtable.willSaveWaitUntil);
}

pub fn semanticTokensFull(self: Handler, params: types.SemanticTokensParams) Error!?types.SemanticTokens {
    return self.nullOrImpl(params, Error!?types.SemanticTokens, self.vtable.semanticTokensFull);
}

pub fn semanticTokensRange(self: Handler, params: types.SemanticTokensRangeParams) Error!?types.SemanticTokens {
    return self.nullOrImpl(params, Error!?types.SemanticTokens, self.vtable.semanticTokensRange);
}

pub fn completion(self: Handler, params: types.CompletionParams) Error!lsp.ResultType("textDocument/completion") {
    return self.nullOrImpl(params, Error!lsp.ResultType("textDocument/completion"), self.vtable.completion);
}

pub fn signatureHelp(self: Handler, params: types.SignatureHelpParams) Error!?types.SignatureHelp {
    return self.nullOrImpl(params, Error!?types.SignatureHelp, self.vtable.signatureHelp);
}

pub fn gotoDefinition(self: Handler, params: types.DefinitionParams) Error!lsp.ResultType("textDocument/definition") {
    return self.nullOrImpl(params, Error!lsp.ResultType("textDocument/definition"), self.vtable.gotoDefinition);
}

pub fn gotoTypeDefinition(self: Handler, params: types.TypeDefinitionParams) Error!lsp.ResultType("textDocument/typeDefinition") {
    return self.nullOrImpl(params, Error!lsp.ResultType("textDocument/typeDefinition"), self.vtable.gotoTypeDefinition);
}

pub fn gotoImplementation(self: Handler, params: types.ImplementationParams) Error!lsp.ResultType("textDocument/implementation") {
    return self.nullOrImpl(params, Error!lsp.ResultType("textDocument/implementation"), self.vtable.gotoImplementation);
}

pub fn gotoDeclaration(self: Handler, params: types.DeclarationParams) Error!lsp.ResultType("textDocument/declaration") {
    return self.nullOrImpl(params, Error!lsp.ResultType("textDocument/declaration"), self.vtable.gotoDeclaration);
}

pub fn documentSymbols(self: Handler, params: types.DocumentSymbolParams) Error!lsp.ResultType("textDocument/documentSymbol") {
    return self.nullOrImpl(params, Error!lsp.ResultType("textDocument/documentSymbol"), self.vtable.documentSymbols);
}

pub fn formatting(self: Handler, params: types.DocumentFormattingParams) Error!?[]types.TextEdit {
    return self.nullOrImpl(params, Error!?[]types.TextEdit, self.vtable.formatting);
}

pub fn rename(self: Handler, params: types.RenameParams) Error!?types.WorkspaceEdit {
    return self.nullOrImpl(params, Error!?types.WorkspaceEdit, self.vtable.rename);
}

pub fn references(self: Handler, params: types.ReferenceParams) Error!?[]types.Location {
    return self.nullOrImpl(params, Error!?[]types.Location, self.vtable.references);
}

pub fn documentHighlight(self: Handler, params: types.DocumentHighlightParams) Error!?[]types.DocumentHighlight {
    return self.nullOrImpl(params, Error!?[]types.DocumentHighlight, self.vtable.documentHighlight);
}

pub fn inlayHint(self: Handler, params: types.InlayHintParams) Error!?[]types.InlayHint {
    return self.nullOrImpl(params, Error!?[]types.InlayHint, self.vtable.inlayHint);
}

pub fn codeAction(self: Handler, params: types.CodeActionParams) Error!lsp.ResultType("textDocument/codeAction") {
    return self.nullOrImpl(params, Error!lsp.ResultType("textDocument/codeAction"), self.vtable.codeAction);
}

pub fn foldingRange(self: Handler, params: types.FoldingRangeParams) Error!?[]types.FoldingRange {
    return self.nullOrImpl(params, Error!?[]types.FoldingRange, self.vtable.foldingRange);
}

pub fn selectionRange(self: Handler, params: types.SelectionRangeParams) Error!?[]types.SelectionRange {
    return self.nullOrImpl(params, Error!?[]types.SelectionRange, self.vtable.selectionRange);
}
