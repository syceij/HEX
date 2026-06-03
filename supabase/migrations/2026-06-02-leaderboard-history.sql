-- ──────────────────────────────────────────────────────────────────────────
-- leaderboard_history — one row per (user × month)
--
-- profiles.leaderboard_data only ever holds the CURRENT month; when the
-- month rolls over it's recalculated and overwritten, so there was no
-- record of past months. This table snapshots each month's score so the
-- Profile "Monthly History" sheet (and friends' profiles) can show a
-- timeline instead of an empty placeholder.
--
-- Written via the snapshot_leaderboard_month() RPC (SECURITY DEFINER —
-- sets user_id = auth.uid() itself, sidestepping the WITH-CHECK fragility
-- we hit with push_devices). Read by any authenticated user, since scores
-- are already semi-public via the leaderboard.
--
-- Idempotent — safe to re-run.
-- ──────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.leaderboard_history (
    user_id          UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    month            TEXT NOT NULL,                    -- "YYYY-MM"
    score            INT  NOT NULL DEFAULT 0,
    sets_completed   INT  NOT NULL DEFAULT 0,
    sets_programmed  INT  NOT NULL DEFAULT 0,
    improvement_pct  INT  NOT NULL DEFAULT 0,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, month)
);

CREATE INDEX IF NOT EXISTS leaderboard_history_user_idx
    ON public.leaderboard_history(user_id);

ALTER TABLE public.leaderboard_history ENABLE ROW LEVEL SECURITY;

-- Read: any authenticated user (same visibility as leaderboard scores).
DROP POLICY IF EXISTS "lh_read" ON public.leaderboard_history;
CREATE POLICY "lh_read"
    ON public.leaderboard_history FOR SELECT
    TO authenticated USING (true);

-- ─── Snapshot RPC ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.snapshot_leaderboard_month(
    p_month           TEXT,
    p_score           INT,
    p_sets_completed  INT,
    p_sets_programmed INT,
    p_improvement_pct INT
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

    INSERT INTO public.leaderboard_history
        (user_id, month, score, sets_completed, sets_programmed, improvement_pct, updated_at)
    VALUES
        (uid, p_month, p_score, p_sets_completed, p_sets_programmed, p_improvement_pct, NOW())
    ON CONFLICT (user_id, month) DO UPDATE
        SET score           = EXCLUDED.score,
            sets_completed  = EXCLUDED.sets_completed,
            sets_programmed = EXCLUDED.sets_programmed,
            improvement_pct = EXCLUDED.improvement_pct,
            updated_at      = NOW();
END;
$$;

REVOKE ALL ON FUNCTION public.snapshot_leaderboard_month(TEXT, INT, INT, INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.snapshot_leaderboard_month(TEXT, INT, INT, INT, INT) TO authenticated;
