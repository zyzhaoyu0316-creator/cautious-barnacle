require 'sinatra'
require 'line/bot'
require 'dotenv/load'
require 'fileutils'
require_relative 'study_partner'

set :public_folder, 'public'
set :bind, '0.0.0.0'

# --- 公開URLの決定 ---------------------------------------------------------
# request.host を使ってURLを組み立てると、Hostヘッダー詐称でPDFのURLが
# 偽装されるリスクがある。そこで Rack::Protection::HostAuthorization で
# 検証するのではなく、そもそも request.host を使わず .env に固定した
# 公開URLだけを信頼する方式にする(ngrok経由だとX-Forwarded-Hostが絡んで
# HostAuthorizationの判定がずれることがあるため、この方がシンプルで確実)。
# .env に PUBLIC_BASE_URL=https://xxxx.ngrok-free.dev のように設定しておく。
PUBLIC_BASE_URL = ENV['PUBLIC_BASE_URL']

configure do
  if PUBLIC_BASE_URL.nil? || PUBLIC_BASE_URL.empty?
    puts "【警告】PUBLIC_BASE_URL が未設定です。.envに設定してください(例: https://xxxx.ngrok-free.dev)。"
  end

  # Sinatra 4.1+ は Rack::Protection::HostAuthorization を組み込みで常時有効化し、
  # デフォルトでは localhost 系のみを許可する。set :protection の except では
  # 制御できず、専用の :host_authorization 設定でしか変更できない。
  # request.host は上記の通り信頼せず PUBLIC_BASE_URL のみを使う設計なので、
  # ここでは許可ホストを空にしてこのチェック自体を無効化する。
  set :host_authorization, { permitted_hosts: [] }
end

# --- PDF保存先 -----------------------------------------------------------
PDF_DIR = File.join(settings.public_folder, 'pdfs')
FileUtils.mkdir_p(PDF_DIR)
PDF_TTL_SECONDS = 60 * 60 * 24 # 24時間で自動削除

def cleanup_old_pdfs
  Dir.glob(File.join(PDF_DIR, '*.pdf')).each do |path|
    if Time.now - File.mtime(path) > PDF_TTL_SECONDS
      File.delete(path) rescue nil
    end
  end
end

def client
  @client ||= Line::Bot::Client.new do |config|
    config.channel_secret = ENV['LINE_CHANNEL_SECRET']
    config.channel_token  = ENV['LINE_CHANNEL_TOKEN']
  end
end

study_partner = StudyPartner.new(gemini_key: ENV['GEMINI_API_KEY'])

post '/callback' do
  body = request.body.read
  signature = request.env['HTTP_X_LINE_SIGNATURE']

  # 署名検証に失敗した場合は必ず処理を止める(なりすましリクエスト対策)
  unless client.validate_signature(body, signature)
    puts "【警告】LINEの署名検証に失敗しました (Signature: #{signature.inspect})"
    halt 400, 'Bad Request'
  end

  cleanup_old_pdfs

  # PDFのURLは常に.envで固定した公開URLから組み立てる(request.hostは使わない)
  base_url = PUBLIC_BASE_URL.to_s.sub(%r{/\z}, '')

  events = client.parse_events_from(body)

  events.each do |event|
    next unless event.is_a?(Line::Bot::Event::Message)

    reply_token = event['replyToken']

    begin
      case event.type
      when Line::Bot::Event::MessageType::Text
        text = event.message['text']
        # 生成に時間がかかる可能性があるため、先に受付メッセージを返す
        client.reply_message(reply_token, {
          type: 'text',
          text: '解説PDFを作成しています。少々お待ちください…📝'
        })
        process_and_push(event, study_partner, base_url) { |t| { text_message: t } }.call(text)

      when Line::Bot::Event::MessageType::Image
        message_id = event.message['id']
        client.reply_message(reply_token, {
          type: 'text',
          text: '画像を受け取りました。解説PDFを作成しています。少々お待ちください…📝'
        })
        response = client.get_message_content(message_id)
        image_binary = response.body
        process_and_push(event, study_partner, base_url) { |_| { image_binary: image_binary } }.call(nil)
      end

    rescue => e
      puts "【エラー詳細】: #{e.message}"
      puts e.backtrace.first(3)
      begin
        client.reply_message(reply_token, {
          type: 'text',
          text: '解説PDFの作成に失敗しました。もう一度試すか、別の画像・テキストをお送りください。'
        })
      rescue => reply_error
        # reply_tokenが既に使用済み・失効している場合はpushで代替
        puts "【返信エラー】: #{reply_error.message}"
        push_error(event['source']['userId'])
      end
    end
  end

  'OK'
end

# PDF生成 + push_message をバックグラウンドで実行するヘルパー。
# reply_tokenは有効期限が短い(数十秒)ため、時間のかかる生成処理は
# reply_message完了後にpush_messageで結果を送る設計にしている。
def process_and_push(event, study_partner, base_url)
  ->(text) {
    user_id = event['source']['userId']
    Thread.new do
      begin
        input = yield(text)
        pdf_filename =
          if input.key?(:text_message)
            study_partner.generate_pdf_from_input(text_message: input[:text_message])
          else
            study_partner.generate_pdf_from_input(image_binary: input[:image_binary])
          end

        if pdf_filename
          pdf_url = "#{base_url}/pdfs/#{pdf_filename}"
          client.push_message(user_id, [
            {
              type: 'text',
              text: "問題の解説PDFができました！下記のリンクからダウンロードしてください😊\n#{pdf_url}"
            }
          ])
        else
          client.push_message(user_id, {
            type: 'text',
            text: '解説PDFの作成に失敗しました。もう一度試すか、別の画像・テキストをお送りください。'
          })
        end
      rescue => e
        puts "【非同期処理エラー】: #{e.message}"
        puts e.backtrace.first(3)
        push_error(user_id)
      end
    end
  }
end

def push_error(user_id)
  return unless user_id
  client.push_message(user_id, {
    type: 'text',
    text: '解説PDFの作成中にエラーが発生しました。もう一度お試しください。'
  })
rescue => e
  puts "【push_messageエラー】: #{e.message}"
end
