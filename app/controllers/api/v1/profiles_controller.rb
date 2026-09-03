module Api
  module V1
    # 验证流程（「后台也看不到你」）：
    #
    #   send_verification_code {email, purpose}      verify_email {email, code}
    #     h = HMAC(pepper, email)                       h = HMAC(pepper, email)
    #     purpose=verify:  verified_emails ∋ h → 409     code(h) 有效? 否 → 400
    #     purpose=release: verified_emails ∌ h → 404     verified_emails ∋ h → 409
    #     INSERT verification_codes(h, code)             TX: INSERT verified_emails(h)
    #     Resend.send(email, code)  ← 明文只在这一帧          UPDATE profiles SET is_verified
    #                                                       DELETE codes(h)
    #
    #   release_verified_email {email, code}   注销前释放：DELETE verified_emails(h)，profile 取消 verified
    #
    # 不变量：任何一行日志/表都不同时含 user_id 与邮箱（含 hash）。
    class ProfilesController < ApplicationController
      rate_limit to: 3, within: 1.minute, only: :send_verification_code,
        by: -> { rate_limit_by_user }, with: -> { render_rate_limited }

      # GET /api/v1/profiles/me
      def me
        json = Rails.cache.fetch("profile/#{current_user_id}", expires_in: 5.minutes) do
          ProfileBlueprint.render(current_user)
        end
        render json: json, status: :ok
      end

      # PATCH /api/v1/profiles/me
      def update
        permitted = params.permit(
          :nickname, :avatar_url, :grade, :major, :gender,
          :show_grade, :show_major, :show_gender
        ).to_h

        # Remove keys not sent by the client (nil = not present in params)
        # but keep empty strings — they mean "clear this field"
        permitted.compact!

        if permitted.empty?
          return render json: { error: { code: "validation_error", message: "No fields to update" } },
                        status: :unprocessable_entity
        end

        # Convert empty strings to nil for nullable text fields (client sends "" to clear)
        %w[nickname grade major gender avatar_url].each do |field|
          permitted[field] = nil if permitted.key?(field) && permitted[field].blank?
        end

        current_user.update!(permitted)
        Rails.cache.delete("profile/#{current_user_id}")
        render json: ProfileBlueprint.render(current_user.reload), status: :ok
      end

      # POST /api/v1/profiles/verify_email
      def verify_email
        email = EmailHasher.normalize(params.require(:email))
        return render_invalid_email unless illinois_email?(email)

        if current_user.is_verified
          return render json: { error: { code: "already_verified", message: "这个账号已经验证过了" } },
                        status: :conflict
        end

        email_hash = EmailHasher.hash(email)
        return render_invalid_code unless consume_code?(email_hash, params.require(:code))

        begin
          ActiveRecord::Base.transaction do
            VerifiedEmail.create!(email_hash: email_hash)
            current_user.update!(is_verified: true)
            VerificationCode.where(email_hash: email_hash).delete_all
          end
        rescue ActiveRecord::RecordNotUnique
          return render_email_already_verified
        end

        Rails.cache.delete("profile/#{current_user_id}")
        Rails.logger.info "[Verify] user=#{current_user_id} verified"
        render json: ProfileBlueprint.render(current_user.reload), status: :ok
      end

      # POST /api/v1/profiles/release_verified_email
      # 注销前把邮箱从 verified_emails 里放出来。我们不知道这个邮箱对应哪个账号，
      # 所以只认验证码（证明邮箱归你），并把当前账号的 is_verified 一并取消。
      def release_verified_email
        email = EmailHasher.normalize(params.require(:email))
        return render_invalid_email unless illinois_email?(email)

        email_hash = EmailHasher.hash(email)
        unless VerifiedEmail.exists?(email_hash: email_hash)
          return render json: { error: { code: "email_not_verified", message: "这个邮箱没有验证过任何账号" } },
                        status: :not_found
        end
        return render_invalid_code unless consume_code?(email_hash, params.require(:code))

        ActiveRecord::Base.transaction do
          VerifiedEmail.where(email_hash: email_hash).delete_all
          VerificationCode.where(email_hash: email_hash).delete_all
          current_user.update!(is_verified: false)
        end

        Rails.cache.delete("profile/#{current_user_id}")
        Rails.logger.info "[Verify] user=#{current_user_id} released"
        render json: ProfileBlueprint.render(current_user.reload), status: :ok
      end

      # POST /api/v1/profiles/request_deletion
      def request_deletion
        if current_user.pending_deletion?
          return render json: { error: { code: "already_pending", message: "Account deletion already requested" } },
                        status: :conflict
        end

        current_user.update!(scheduled_deletion_at: 30.days.from_now)
        Rails.cache.delete("profile/#{current_user_id}")
        render json: ProfileBlueprint.render(current_user.reload), status: :ok
      end

      # POST /api/v1/profiles/cancel_deletion
      def cancel_deletion
        unless current_user.pending_deletion?
          return render json: { error: { code: "not_pending", message: "No pending deletion to cancel" } },
                        status: :conflict
        end

        current_user.update!(scheduled_deletion_at: nil)
        Rails.cache.delete("profile/#{current_user_id}")
        render json: ProfileBlueprint.render(current_user.reload), status: :ok
      end

      SEND_PURPOSES = %w[verify release].freeze

      # POST /api/v1/profiles/send_verification_code
      # purpose=verify（默认）：邮箱不能已验证过；purpose=release：邮箱必须已验证过
      def send_verification_code
        email = EmailHasher.normalize(params.require(:email))
        return render_invalid_email unless illinois_email?(email)

        purpose = params.fetch(:purpose, "verify").to_s
        unless SEND_PURPOSES.include?(purpose)
          return render json: { error: { code: "validation_error", message: "purpose 必须是 verify 或 release" } },
                        status: :unprocessable_entity
        end

        email_hash = EmailHasher.hash(email)
        already_verified = VerifiedEmail.exists?(email_hash: email_hash)
        return render_email_already_verified if purpose == "verify" && already_verified
        if purpose == "release" && !already_verified
          return render json: { error: { code: "email_not_verified", message: "这个邮箱没有验证过任何账号" } },
                        status: :not_found
        end

        recent = VerificationCode.where(email_hash: email_hash).order(created_at: :desc).first
        if recent && recent.created_at > 60.seconds.ago
          remaining = 60 - (Time.current - recent.created_at).to_i
          return render json: { error: { code: "rate_limited", message: "请等待 #{remaining} 秒后重试" } },
                        status: :too_many_requests
        end

        code = SecureRandom.random_number(100_000..999_999).to_s
        VerificationCode.create!(email_hash: email_hash, code: code, expires_at: 10.minutes.from_now)

        # 明文邮箱只在这一次调用里存在：不落库、不落日志
        ResendEmailService.send_verification_code(email: email, code: code)

        VerificationCode.expired.where(email_hash: email_hash).delete_all

        render json: { success: true, message: "验证码已发送" }, status: :ok
      rescue ResendEmailService::DeliveryError => e
        render json: { error: { code: "send_failed", message: e.message } },
              status: :internal_server_error
      end

      private

      def illinois_email?(email)
        email.end_with?("@illinois.edu")
      end

      def consume_code?(email_hash, code)
        VerificationCode.active.where(email_hash: email_hash, code: code.to_s).exists?
      end

      def render_invalid_email
        render json: { error: { code: "invalid_email", message: "请输入有效的 @illinois.edu 邮箱" } },
               status: :bad_request
      end

      def render_invalid_code
        render json: { error: { code: "invalid_code", message: "验证码无效或已过期" } },
               status: :bad_request
      end

      def render_email_already_verified
        render json: { error: { code: "email_already_verified",
                                message: "这个邮箱已经验证过一个账号了，请用原来的登录方式进入。我们不知道那是哪个账号——这正是设计如此" } },
               status: :conflict
      end
    end
  end
end
