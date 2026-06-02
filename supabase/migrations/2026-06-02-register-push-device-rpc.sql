-- ──────────────────────────────────────────────────────────────────────────
-- register_push_device() — RPC for device-token registration
--
-- The client-side upsert into push_devices was failing with
-- "new row violates row-level security policy" even for authenticated
-- users. Rather than depend on the INSERT policy's WITH CHECK
-- (user_id = auth.uid()) matching a client-supplied user_id, this
-- SECURITY DEFINER function sets user_id = auth.uid() itself and does
-- the upsert as the function owner — the same proven pattern as
-- delete_current_user(). No possibility of a user_id mismatch, and the
-- table's RLS is bypassed for this one controlled write path.
--
-- Idempotent — safe to re-run.
-- ──────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.register_push_device(
    p_device_token TEXT,
    p_platform     TEXT,
    p_is_sandbox   BOOLEAN,
    p_app_version  TEXT
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    uid uuid;
BEGIN
    uid := auth.uid();
    IF uid IS NULL THEN
        RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '42501';
    END IF;

    INSERT INTO public.push_devices
        (user_id, device_token, platform, is_sandbox, app_version, updated_at)
    VALUES
        (uid, p_device_token, p_platform, COALESCE(p_is_sandbox, false), p_app_version, NOW())
    ON CONFLICT (device_token) DO UPDATE
        SET user_id     = EXCLUDED.user_id,
            platform    = EXCLUDED.platform,
            is_sandbox  = EXCLUDED.is_sandbox,
            app_version = EXCLUDED.app_version,
            updated_at  = NOW();
END;
$$;

REVOKE ALL ON FUNCTION public.register_push_device(TEXT, TEXT, BOOLEAN, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_push_device(TEXT, TEXT, BOOLEAN, TEXT) TO authenticated;
