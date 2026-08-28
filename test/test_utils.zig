const std = @import("std");
const ndq = @import("ndq");
const lexer = ndq.lexer;
const parser = ndq.parser;

pub fn isTokenEqual(a: lexer.Token, b: lexer.Token) bool {
    return if (a.start_offset != b.start_offset)
        false
    else if (a.type != b.type)
        false
    else if (a.end_offset != b.end_offset)
        false
    else if (a.keyword != b.keyword)
        false
    else if (!std.mem.eql(u8, a.raw, b.raw))
        false
    else
        true;
}

pub fn isTermEqual(a: parser.Term, b: parser.Term) bool {
    if (a.kind != b.kind) return false;
    if (a.value.len != b.value.len) return false;

    for (a.value, b.value) |aval, bval| {
        if (!isTokenEqual(aval, bval)) return false;
    }
    return true;
}

/// Recursivly check the Ast is equivalent by value
pub fn isAstEqual(a: *const parser.ASTNode, b: *const parser.ASTNode) bool {
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;

    switch (a.*) {
        .comp => |a_comp| {
            const b_comp = b.comp;
            if (a_comp.op != b_comp.op) return false;
            if (a_comp.tokens_consumed != b_comp.tokens_consumed) return false;
            if (!isTermEqual(a_comp.term1, b_comp.term1)) return false;
            if (!isTermEqual(a_comp.term2, b_comp.term2)) return false;
        },
        .exp => |a_exp| {
            const b_exp = b.exp;
            if (a_exp.tokens_consumed != b_exp.tokens_consumed) return false;
            if (a_exp.oprands.len != b_exp.oprands.len) return false;
            if (a_exp.type != b_exp.type) return false;

            for (a_exp.oprands, b_exp.oprands) |aop, bop| {
                if (!isAstEqual(aop, bop)) return false;
            }
        },
    }
    return true;
}
