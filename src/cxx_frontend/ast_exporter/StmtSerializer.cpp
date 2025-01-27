#include "AstSerializer.h"
#include "clang/AST/Stmt.h"

namespace vf {

using StmtNodeOrphan = NodeOrphan<stubs::Stmt>;
bool StmtSerializer::VisitCompoundStmt(const clang::CompoundStmt *stmt) {
  auto orphanage = capnp::Orphanage::getForMessageContaining(_builder);

  llvm::SmallVector<StmtNodeOrphan, 32> stmtNodeOrphans;

  auto &store = _serializer.getAnnStore();

  auto &SM = getSourceManager();

  clang::SourceLocation currentLoc;
  for (auto s : stmt->body()) {
    std::list<Annotation> anns;
    store.getUntilLoc(anns, s->getBeginLoc(), SM);
    _serializer.serializeAnnsToOrphans(anns, orphanage, stmtNodeOrphans);
    _serializer.serializeToOrphan(s, orphanage, stmtNodeOrphans);
    currentLoc = s->getEndLoc();
  }

  std::list<Annotation> anns;
  store.getUntilLoc(anns, stmt->getRBracLoc(), SM);
  _serializer.serializeAnnsToOrphans(anns, orphanage, stmtNodeOrphans);

  auto comp = _builder.initCompound();
  auto children = comp.initStmts(stmtNodeOrphans.size());
  AstSerializer::adoptOrphansToListBuilder(stmtNodeOrphans, children);

  auto rBrace = comp.initRBrace();
  auto rBraceLoc = stmt->getRBracLoc();
  serializeSrcRange(rBrace, {rBraceLoc, rBraceLoc}, SM);

  return true;
}

bool StmtSerializer::VisitReturnStmt(const clang::ReturnStmt *stmt) {
  auto ret = _builder.initReturn();
  auto retVal = stmt->getRetValue();

  if (retVal) {
    auto retExpr = ret.initExpr();
    _serializer.serializeExpr(retExpr, retVal);
  }
  return true;
}

bool StmtSerializer::VisitDeclStmt(const clang::DeclStmt *stmt) {
  auto nbChildren = std::distance(stmt->decl_begin(), stmt->decl_end());
  auto children = _builder.initDecl(nbChildren);

  size_t i(0);
  for (auto it = stmt->decl_begin(); it != stmt->decl_end(); ++it, ++i) {
    auto child = children[i];
    _serializer.serializeDecl(child, *it);
  }
  return true;
}

bool StmtSerializer::VisitExpr(const clang::Expr *stmt) {
  auto expr = _builder.initExpr();

  _serializer.serializeExpr(expr, stmt);
  return true;
}

bool StmtSerializer::VisitIfStmt(const clang::IfStmt *stmt) {
  auto ifStmt = _builder.initIf();

  auto cond = ifStmt.initCond();
  _serializer.serializeExpr(cond, stmt->getCond());

  auto then = ifStmt.initThen();
  _serializer.serializeStmt(then, stmt->getThen());

  if (stmt->hasElseStorage()) {
    auto el = ifStmt.initElse();
    _serializer.serializeStmt(el, stmt->getElse());
  }
  return true;
}

bool StmtSerializer::VisitNullStmt(const clang::NullStmt *stmt) {
  _builder.setNull();
  return true;
}

template <class While>
bool StmtSerializer::visitWhi(stubs::Stmt::While::Builder &builder,
                              const While *stmt) {

  auto cond = builder.initCond();
  _serializer.serializeExpr(cond, stmt->getCond());

  std::list<Annotation> anns;
  _serializer.getAnnStore().getUntilLoc(anns, stmt->getBody()->getBeginLoc(),
                                    getSourceManager());
  auto specBuilder = builder.initSpec(anns.size());
  size_t i(0);
  for (auto &ann : anns) {
    auto annBuilder = specBuilder[i++];
    _serializer.serializeAnnotationClause(annBuilder, ann);
  }

  auto whileLoc = builder.initWhileLoc();
  auto whileBegin = stmt->getWhileLoc();
  serializeSrcRange(whileLoc, {whileBegin, whileBegin}, getSourceManager());

  auto body = builder.initBody();
  _serializer.serializeStmt(body, stmt->getBody());
  return true;
}

bool StmtSerializer::VisitWhileStmt(const clang::WhileStmt *stmt) {
  auto whi = _builder.initWhile();
  return visitWhi(whi, stmt);
}

bool StmtSerializer::VisitDoStmt(const clang::DoStmt *stmt) {
  auto doWhi = _builder.initDoWhile();
  return visitWhi(doWhi, stmt);
}

bool StmtSerializer::VisitBreakStmt(const clang::BreakStmt *stmt) {
  _builder.setBreak();
  return true;
}

bool StmtSerializer::VisitContinueStmt(const clang::ContinueStmt *stmt) {
  _builder.setContinue();
  return true;
}

bool StmtSerializer::VisitSwitchStmt(const clang::SwitchStmt *stmt) {
  auto sw = _builder.initSwitch();

  auto cond = sw.initCond();
  _serializer.serializeExpr(cond, stmt->getCond());

  llvm::SmallVector<const clang::Stmt *, 4> casesPtrs;
  for (auto swCase = stmt->getSwitchCaseList(); swCase;
       swCase = swCase->getNextSwitchCase()) {
    casesPtrs.push_back(swCase);
  }

  auto cases = sw.initCases(casesPtrs.size());
  size_t i(casesPtrs.size());
  // clang traverses them in reverse order, so we reverse it again
  for (auto swCase : casesPtrs) {
    auto cas = cases[--i];
    _serializer.serializeStmt(cas, swCase);
  }
  return true;
}

bool StmtSerializer::VisitCaseStmt(const clang::CaseStmt *stmt) {
  auto swCase = _builder.initCase();

  auto lhs = swCase.initLhs();
  _serializer.serializeExpr(lhs, stmt->getLHS());

  auto rhs = stmt->getRHS();
  // check if it has a rhs. Otherwise 'getSubsStmt' would point to the next case
  // in the switch, because that next case would be treated as a sub statement
  // in the current case statement.
  if (rhs) {
    auto subStmt = swCase.initStmt();
    _serializer.serializeStmt(subStmt, stmt->getSubStmt());
  }
  return true;
}

bool StmtSerializer::VisitDefaultStmt(const clang::DefaultStmt *stmt) {
  auto defStmt = _builder.initDefCase();
  auto subStmt = stmt->getSubStmt();
  if (subStmt) {
    auto sub = defStmt.initStmt();
    _serializer.serializeStmt(sub, subStmt);
  }
  return true;
}

} // namespace vf