# Shared helpers for the dummy app's executables. Talks to postgres and
# redis by shelling out to psql and redis-cli so no gems are required.
module DummyApp
  DATABASE_URL = ENV.fetch("DATABASE_URL")
  REDIS_URL = ENV.fetch("REDIS_URL")

  module_function

  def psql(sql)
    out = IO.popen(["psql", DATABASE_URL, "-tAc", sql], &:read)
    raise "psql failed: #{sql}" unless $?.success?

    out.strip
  end

  def redis(*args)
    out = IO.popen(["redis-cli", "-u", REDIS_URL, *args], &:read)
    raise "redis-cli failed: #{args.join(' ')}" unless $?.success?

    out.strip
  end
end
