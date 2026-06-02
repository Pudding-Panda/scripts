FROM elixir:1.17-otp-27-slim AS build

RUN apt-get update && apt-get install -y gcc make ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY config ./config
COPY lib ./lib
RUN mix compile && mix release

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y libstdc++6 openssl libncurses6 locales && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen && \
    rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8

WORKDIR /app
RUN mkdir -p /data

COPY --from=build /app/_build/prod/rel/devtime_server ./

EXPOSE 7879

CMD ["bin/devtime_server", "start"]
