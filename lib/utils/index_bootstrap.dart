enum IndexLoadDisposition { ready, rebuildConfigured, rebuildCompact }

/// 将原生索引载入结果转换为启动动作。
///
/// 原生以 -1 表示索引已因超出内存预算或损坏而重置；这种情况必须关闭
/// deepDataIndex 后精简重建，不能与普通空库（0）走同一配置。
IndexLoadDisposition classifyIndexLoad(int entryCount) {
  if (entryCount < 0) return IndexLoadDisposition.rebuildCompact;
  if (entryCount == 0) return IndexLoadDisposition.rebuildConfigured;
  return IndexLoadDisposition.ready;
}
