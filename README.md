# redmine-theme-data

## 概要

[redmine-theme/storybook](https://github.com/redmine-theme/storybook) 用のRedmineのフィクスチャデータとDocker設定を管理するディレクトリです。

## Dockerコンテナの起動

```sh
cd branches/6.0-stable
cp .env.example .env
docker compose up
```
Railsサービス起動後、ブラウザで http://localhost:3000 にアクセスしてRedmineにログインします。
デフォルトのログイン情報は以下の通りです。
- ユーザー名: `admin`
- パスワード: `password`

## フィクスチャの保存

```sh
cd branches/6.0-stable
docker compose exec redmine rake -R ./tasks extract_fixtures_ext \
  DIR=./fixtures \
  SKIP_TABLES=tokens \
  OMIT_DEFAULT_OR_NIL=true
```
