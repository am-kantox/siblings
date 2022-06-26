import Config

config :telemetria,
  otp_app: :siblings,
  enabled: true,
  applications: [siblings: true],
  events: [[:siblings, :internal_worker, :safe_perform]],
  polling: [enabled: false, flush: 60_000, poll: 60_000]
