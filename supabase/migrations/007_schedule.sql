-- =============================================================================
-- CIP POC on Supabase · 007 schedules (pg_cron)
--   cip-simulator       two simulator steps every 5 seconds
--   cip-nightly-reseed  rebuild the demo data at 02:00 GST (22:00 UTC) so the
--                       relative-time seed stays fresh and the tables stay small
-- Stop the simulator:  select cron.unschedule('cip-simulator');
-- Pause it:            select cron.alter_job((select jobid from cron.job where jobname = 'cip-simulator'), active := false);
-- =============================================================================
create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;

select cron.schedule('cip-simulator', '5 seconds', $$select cip_ingest.simulate_tick()$$);
select cron.schedule('cip-nightly-reseed', '0 22 * * *', $$select cip_ingest.seed_demo()$$);
select cron.schedule('cip-cron-history-cleanup', '15 * * * *',
  $$delete from cron.job_run_details where end_time < now() - interval '6 hours'$$);
