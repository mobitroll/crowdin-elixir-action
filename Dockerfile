FROM elixir:1.10

RUN mkdir /app
COPY . /app
WORKDIR /app

RUN mix local.hex --force
RUN mix deps.get
RUN mix compile

ENTRYPOINT ["/app/entrypoint.sh"]