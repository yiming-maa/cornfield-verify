class ResendEmailService
  API_URL = "https://api.resend.com/emails"
  API_KEY = ENV["RESEND_API_KEY"]
  TIMEOUT_SECONDS = 5

  class DeliveryError < StandardError; end

  def self.send_verification_code(email:, code:)
    unless API_KEY.present?
      if Rails.env.development?
        Rails.logger.warn "[ResendEmail] RESEND_API_KEY not set — email skipped. Code: #{code}"
      else
        Rails.logger.warn "[ResendEmail] RESEND_API_KEY not set — email skipped"
      end
      return
    end

    uri = URI(API_URL)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = TIMEOUT_SECONDS
    http.read_timeout = TIMEOUT_SECONDS

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{API_KEY}"
    request.body = {
      from: "玉米地里 <noreply@illinicornfield.com>",
      to: [email],
      subject: "你的验证码",
      html: verification_html(code)
    }.to_json

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = http.request(request)
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1)

    if response.code.start_with?("2")
      Rails.logger.info "[ResendEmail] delivered in #{duration_ms}ms"
    else
      Rails.logger.error "[ResendEmail] HTTP #{response.code} in #{duration_ms}ms: #{response.body}"
      raise DeliveryError, "邮件发送失败"
    end
  rescue Timeout::Error, Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
    Rails.logger.error "[ResendEmail] #{e.class}: #{e.message}"
    raise DeliveryError, "邮件服务不可用"
  end

  def self.verification_html(code)
    <<~HTML
      <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 400px; margin: 0 auto; padding: 32px 24px;">
        <h2 style="color: #F47521; margin: 0 0 8px 0; font-size: 24px;">玉米地里</h2>
        <p style="color: #999; font-size: 13px; margin: 0 0 28px 0;">玉米地里上学，玉米地里聊</p>
        <p style="color: #333; font-size: 16px; margin: 0 0 16px 0;">你的验证码是：</p>
        <h1 style="letter-spacing: 8px; font-size: 36px; color: #F47521; margin: 0 0 24px 0; font-weight: 700;">#{code}</h1>
        <p style="color: #666; font-size: 14px; margin: 0 0 32px 0;">验证码有效期 10 分钟，请勿泄露给他人。</p>
        <div style="border-top: 1px solid #eee; padding-top: 16px;">
          <p style="color: #999; font-size: 12px; margin: 0;">玉米地里 · UIUC 校园社区</p>
        </div>
      </div>
    HTML
  end
end
