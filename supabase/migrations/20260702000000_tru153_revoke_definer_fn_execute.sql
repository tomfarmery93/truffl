-- TRU-153: revoke public API EXECUTE on internal SECURITY DEFINER functions.
--
-- These run only from triggers or the rolling cron, which execute the function in the
-- definer's context regardless of the session role's EXECUTE grant — so revoking EXECUTE
-- from anon/authenticated does NOT stop them firing. But they were reachable directly over
-- PostgREST at /rest/v1/rpc/*, letting an unauthenticated caller e.g. materialise bookings
-- (generate_series_bookings) or invoke trigger functions. This closes that.
--
-- mark_meet_greet_complete stays granted to authenticated (the client calls it intentionally).
-- Leaves PostGIS st_estimatedextent alone (extension-owned).
--
-- Applied to the live DB via apply_migration; committed for version control.

revoke execute on function public.generate_series_bookings(uuid, integer) from public, anon, authenticated;
revoke execute on function public.roll_all_series_bookings() from public, anon, authenticated;
revoke execute on function public.trg_series_activated() from public, anon, authenticated;
revoke execute on function public.trg_series_cancelled() from public, anon, authenticated;
revoke execute on function public.messages_bump_conversation() from public, anon, authenticated;
revoke execute on function public.messages_set_conversation() from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
