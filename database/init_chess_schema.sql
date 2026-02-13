-- Chess Platform PostgreSQL schema (idempotent)
-- This file is executed by database/startup.sh after the DB/user are created.

BEGIN;

-- Enable crypto-grade UUID generation
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------- Enums ----------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'game_status') THEN
    CREATE TYPE game_status AS ENUM ('WAITING', 'ACTIVE', 'COMPLETED', 'ABORTED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'game_result') THEN
    CREATE TYPE game_result AS ENUM ('WHITE_WIN', 'BLACK_WIN', 'DRAW', 'ABORTED', 'UNKNOWN');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'player_color') THEN
    CREATE TYPE player_color AS ENUM ('WHITE', 'BLACK');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'matchmaking_status') THEN
    CREATE TYPE matchmaking_status AS ENUM ('QUEUED', 'MATCHED', 'CANCELLED');
  END IF;
END $$;

-- ---------- users ----------
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  username TEXT NOT NULL UNIQUE,
  email TEXT UNIQUE,
  password_hash TEXT NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_login_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_users_created_at ON users(created_at);

-- ---------- sessions / tokens ----------
CREATE TABLE IF NOT EXISTS auth_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ,
  user_agent TEXT,
  ip_address INET
);

CREATE INDEX IF NOT EXISTS idx_auth_sessions_user_id ON auth_sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_auth_sessions_expires_at ON auth_sessions(expires_at);

-- ---------- games ----------
CREATE TABLE IF NOT EXISTS games (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  white_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  black_user_id UUID REFERENCES users(id) ON DELETE SET NULL,

  status game_status NOT NULL DEFAULT 'WAITING',
  result game_result NOT NULL DEFAULT 'UNKNOWN',

  -- Core game state snapshots
  initial_fen TEXT NOT NULL DEFAULT 'startpos',
  current_fen TEXT NOT NULL DEFAULT 'startpos',

  -- Optional PGN snapshot (can be recomputed from moves)
  pgn TEXT,

  started_at TIMESTAMPTZ,
  ended_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_games_created_at ON games(created_at);
CREATE INDEX IF NOT EXISTS idx_games_status ON games(status);
CREATE INDEX IF NOT EXISTS idx_games_white_user_id ON games(white_user_id);
CREATE INDEX IF NOT EXISTS idx_games_black_user_id ON games(black_user_id);

-- ---------- moves ----------
CREATE TABLE IF NOT EXISTS game_moves (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  game_id UUID NOT NULL REFERENCES games(id) ON DELETE CASCADE,
  move_number INTEGER NOT NULL CHECK (move_number > 0),
  ply INTEGER NOT NULL CHECK (ply > 0), -- half-move count (1=white's first move)
  color player_color NOT NULL,
  uci TEXT NOT NULL, -- e.g. "e2e4"
  san TEXT,          -- e.g. "e4"
  fen_after TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (game_id, ply)
);

CREATE INDEX IF NOT EXISTS idx_game_moves_game_id ON game_moves(game_id);
CREATE INDEX IF NOT EXISTS idx_game_moves_game_id_ply ON game_moves(game_id, ply);

-- ---------- matchmaking queue ----------
CREATE TABLE IF NOT EXISTS matchmaking_queue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status matchmaking_status NOT NULL DEFAULT 'QUEUED',
  preferred_color player_color, -- NULL means no preference
  rating INTEGER NOT NULL DEFAULT 1200 CHECK (rating > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  matched_game_id UUID REFERENCES games(id) ON DELETE SET NULL,
  matched_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ,
  UNIQUE (user_id) -- user can only be in queue once
);

CREATE INDEX IF NOT EXISTS idx_matchmaking_queue_status_created_at ON matchmaking_queue(status, created_at);

-- ---------- results / per-user outcomes ----------
-- This table denormalizes game results per user for fast history queries.
CREATE TABLE IF NOT EXISTS game_results (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  game_id UUID NOT NULL UNIQUE REFERENCES games(id) ON DELETE CASCADE,
  white_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  black_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  result game_result NOT NULL,
  reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_game_results_created_at ON game_results(created_at);
CREATE INDEX IF NOT EXISTS idx_game_results_white_user_id ON game_results(white_user_id);
CREATE INDEX IF NOT EXISTS idx_game_results_black_user_id ON game_results(black_user_id);

-- ---------- seed data ----------
-- Note: password_hash here is a placeholder string; backend should store real hashes.
INSERT INTO users (username, email, password_hash)
VALUES
  ('demo_white', 'demo_white@example.com', 'DEMO_HASH_CHANGE_ME'),
  ('demo_black', 'demo_black@example.com', 'DEMO_HASH_CHANGE_ME')
ON CONFLICT (username) DO NOTHING;

COMMIT;
