#!/usr/bin/env ruby
# frozen_string_literal: true

# ----------------------------------------------------
# 複数の client.rb を読んで、メソッド定義＋コメントを
# まとめて aggregator を作るサンプルスクリプト
# ----------------------------------------------------

# あらかじめ対象のファイルをハードコードする
files = [
  "./lib/line/bot/v2/messaging_api/api/messaging_api_client.rb",
  "./lib/line/bot/v2/messaging_api/api/messaging_api_blob_client.rb"
  # 他にもあれば追加
]

# 生成する Aggregator の完全修飾モジュール名やクラス名
AGGREGATOR_MODULE = %w[Line Bot V2 AllInOne]
AGGREGATOR_CLASS  = 'ApiClient'

# サブクライアントを持っておく配列
subclients = []

# 各ファイルから抽出したメソッド定義データを格納する
# 配列の要素: { submodule_name: "Foo", methods: [ { name: "broadcast", docs: ["# ...", "# ..."], signature: "def broadcast(...)" }, ... ] }
extracted_data = []

files.each do |file_path|
  content = File.read(file_path)

  # 1) サブモジュール名(例: Foo) を取得する
  #    「module Line::Bot::V2::XXXX のXXXX部分を取る」という想定
  #    ここではサンプルとして雑に正規表現で抜いている
  submodule_name = nil
  if content =~ %r{module\sLine\s+module\sBot\s+module\sV2\s+module\s(\S+)\s+}
    submodule_name = Regexp.last_match(1)
  else
    warn "WARN: Could not find submodule in #{file_path}"
    next
  end

  # 2) メソッド定義をコメントごと取得
  methods_data = []
  lines = content.each_line.map(&:chomp)

  # コメント行とメソッド定義を紐づけるバッファ
  current_docs = []
  lines.each do |line|
    if line.strip.start_with?('#')
      # def が始まる前のコメント行をため込む
      current_docs << line
    elsif line.strip.start_with?('def ')
      # メソッド定義の行を取得
      method_def = line.strip
      # ため込んだコメントとセットで保存してリセット
      methods_data << {
        docs: current_docs,
        signature: method_def,
      }
      current_docs = []
    else
      # それ以外の行はコメントとしては無関係なのでリセット
      # あるいはリセットせずに def が出るまで保持したい場合は要調整
      current_docs = []
    end
  end

  # 3) ファイルごとの結果を格納
  extracted_data << {
    submodule_name: submodule_name,
    methods: methods_data,
  }

  # 4) initialize で使うための「@xxx_client = ::Line::Bot::V2::Xxx::ApiClient.new(...)」の情報を保持
  subclients << submodule_name
end

# ここまでで、各ファイルに定義されているメソッド＋コメントを extracted_data に貯められている状態
# これを使って Aggregator クラスのコードを組み立てる

result = +""
# モジュール定義 (Line::Bot::V2::AllInOne など)
AGGREGATOR_MODULE.each_with_index do |mod_name, i|
  indent = "  " * i
  result << "#{indent}module #{mod_name}\n"
end
# クラス定義開始
indent = "  " * AGGREGATOR_MODULE.size
result << "#{indent}class #{AGGREGATOR_CLASS}\n"

# ---------------------------------
# まずは initialize
# 適宜引数は編集してください
# ---------------------------------
result << <<~RUBY.gsub(/^/, indent + "  ")
  # Aggregator を初期化。
  # 全てのサブクライアントを生成します。
  #
  # @param base_url [String] ...
  # @param channel_access_token [String] ...
  # @param http_options [Hash] ...
  def initialize(base_url: nil, channel_access_token:, http_options: {})
RUBY

subclients.each do |submodule_name|
  # サブクライアントのインスタンス変数名を決める
  ivar_name = "@#{submodule_name.downcase}_client"

  # サブクライアント生成コード（単純な例）
  result << "#{indent}    #{ivar_name} = ::Line::Bot::V2::#{submodule_name}::ApiClient.new(\n"
  result << "#{indent}      base_url: base_url,\n"
  result << "#{indent}      channel_access_token: channel_access_token,\n"
  result << "#{indent}      http_options: http_options\n"
  result << "#{indent}    )\n"
end
result << "#{indent}  end\n\n"

# ---------------------------------
# delegate 用メソッド定義
# ---------------------------------
extracted_data.each do |data|
  submodule_name = data[:submodule_name]
  ivar_name = "@#{submodule_name.downcase}_client"

  data[:methods].each do |method_info|
    docs = method_info[:docs]
    signature = method_info[:signature]

    # docs をそのまま出力する
    docs.each do |doc_line|
      result << "#{indent}  #{doc_line}\n"
    end

    # `def broadcast(...)` などの `def` 行を解析して
    # メソッド名・引数部分を抜き出す (ナイーブな方法)
    # 例: def broadcast_with_http_info(broadcast_request:, x_line_retry_key: nil)
    # 正規表現で method_name と引数リストに分割
    if signature =~ /^def\s+([^(]+)\((.*)\)/
      method_name = Regexp.last_match(1).strip
      args_str    = Regexp.last_match(2).strip
    elsif signature =~ /^def\s+([^(]+)\s*$/
      # 引数なしメソッドの場合
      method_name = Regexp.last_match(1).strip
      args_str = ""
    else
      # パターン外ならそのままコピーする
      method_name = signature.sub(/^def\s+/, '')
      args_str    = ""
    end

    # aggregator 用に同じシグニチャを再利用したメソッド定義
    if args_str.empty?
      # 引数無しの場合
      result << "#{indent}  def #{method_name}\n"
      result << "#{indent}    #{ivar_name}.#{method_name}\n"
      result << "#{indent}  end\n\n"
    else
      # 引数有り
      result << "#{indent}  def #{method_name}(#{args_str})\n"
      result << "#{indent}    #{ivar_name}.#{method_name}(#{args_str})\n"
      result << "#{indent}  end\n\n"
    end
  end
end

# クラス・モジュール定義を閉じる
result << "#{indent}end\n"
AGGREGATOR_MODULE.size.times do |i|
  indent = "  " * (AGGREGATOR_MODULE.size - 1 - i)
  result << "#{indent}end\n"
end

# ---------------------------------
# 出力 (標準出力へ)
# ---------------------------------
puts result