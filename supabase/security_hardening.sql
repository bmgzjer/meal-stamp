-- 已在 2026-09-04 应用到线上项目。
-- 作用：把 RLS 辅助函数移出 public API schema，缩小 RPC 暴露面。
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

-- 线上完整 hardening 已通过 Supabase migration 应用。
-- 新项目请先运行 schema.sql，再运行本文件对应的线上 migration；
-- 当前最终工程优先连接已配置好的现有项目，无需重复执行。
