require "rails_helper"

RSpec.describe "Api::V1::Profiles", type: :request do
  let(:user_id) { SecureRandom.uuid }
  let(:headers) { auth_headers(user_id) }

  before do
    create_auth_user(id: user_id)
    create(:profile, id: user_id, nickname: "TestUser", grade: "Junior", major: "CS")
  end

  describe "GET /api/v1/profile/me" do
    it "returns current user profile" do
      get "/api/v1/profile/me", headers: headers

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data["id"]).to eq(user_id)
      expect(data["nickname"]).to eq("TestUser")
      expect(data["grade"]).to eq("Junior")
      expect(data["major"]).to eq("CS")
      expect(data).not_to have_key("uiuc_email")
      expect(data["show_grade"]).to eq(true)
      expect(data["created_at"]).to be_present
    end

    it "requires authentication" do
      get "/api/v1/profile/me"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "PATCH /api/v1/profile/me" do
    it "updates profile fields" do
      patch "/api/v1/profile/me", params: {
        nickname: "NewName",
        grade: "Senior"
      }, headers: headers

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data["nickname"]).to eq("NewName")
      expect(data["grade"]).to eq("Senior")
      expect(data["major"]).to eq("CS")
    end

    it "returns 422 when no fields provided" do
      patch "/api/v1/profile/me", params: {}, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "updates boolean fields" do
      patch "/api/v1/profile/me", params: {
        show_grade: false,
        show_major: false
      }, headers: headers

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data["show_grade"]).to eq(false)
      expect(data["show_major"]).to eq(false)
    end

    it "clears nullable fields when sent as empty string" do
      patch "/api/v1/profile/me", params: {
        grade: "",
        gender: ""
      }, headers: headers

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data["grade"]).to be_nil
      expect(data["gender"]).to be_nil
      expect(data["major"]).to eq("CS")  # unchanged
    end

    it "requires authentication" do
      patch "/api/v1/profile/me", params: { nickname: "Hacker" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /api/v1/profile/verify_email" do
    let(:email) { "testuser@illinois.edu" }

    it "verifies email with valid code and stores only the hash, never linked to the user" do
      code = create(:verification_code, email: email)

      post "/api/v1/profile/verify_email", params: { email: email, code: code.code }, headers: headers

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data).not_to have_key("uiuc_email")
      expect(data["is_verified"]).to eq(true)
      expect(VerifiedEmail.verified?(email)).to be true
      expect(VerificationCode.for_email(email).count).to eq(0)
      profile = Profile.find(user_id)
      expect(profile.uiuc_email).to be_nil
      expect(profile.email_hash).to be_nil
    end

    it "normalizes case/whitespace before hashing" do
      code = create(:verification_code, email: email)

      post "/api/v1/profile/verify_email", params: { email: " TestUser@illinois.edu ", code: code.code }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(VerifiedEmail.verified?(email)).to be true
    end

    it "returns 400 for invalid code" do
      create(:verification_code, email: email, code: "111111")

      post "/api/v1/profile/verify_email", params: { email: email, code: "999999" }, headers: headers

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["error"]["code"]).to eq("invalid_code")
    end

    it "returns 400 for expired code" do
      create(:verification_code, email: email, code: "123456", expires_at: 1.minute.ago)

      post "/api/v1/profile/verify_email", params: { email: email, code: "123456" }, headers: headers

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["error"]["code"]).to eq("invalid_code")
    end

    it "returns 400 for non-illinois.edu email" do
      post "/api/v1/profile/verify_email", params: { email: "test@gmail.com", code: "123456" }, headers: headers

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["error"]["code"]).to eq("invalid_email")
    end

    it "returns 409 when the email already verified another account, without merging or revealing it" do
      other_id = SecureRandom.uuid
      create_auth_user(id: other_id)
      create(:profile, id: other_id, is_verified: true, nickname: "OldNickname")
      create(:verified_email, email: email)
      code = create(:verification_code, email: email)

      post "/api/v1/profile/verify_email", params: { email: email, code: code.code }, headers: headers

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["error"]["code"]).to eq("email_already_verified")
      expect(response.body).not_to include(other_id)
      expect(Profile.find(user_id).is_verified).to eq(false)
      expect(Profile.find(other_id).is_deleted).to eq(false)
    end

    it "returns 409 when the current account is already verified" do
      Profile.find(user_id).update!(is_verified: true)
      code = create(:verification_code, email: email)

      post "/api/v1/profile/verify_email", params: { email: email, code: code.code }, headers: headers

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["error"]["code"]).to eq("already_verified")
    end

    it "does not log the email or its hash on the same line as the user id" do
      code = create(:verification_code, email: email)
      lines = []
      allow(Rails.logger).to receive(:info) { |msg| lines << msg.to_s }

      post "/api/v1/profile/verify_email", params: { email: email, code: code.code }, headers: headers

      user_lines = lines.select { |l| l.include?(user_id) }
      expect(user_lines).not_to be_empty
      user_lines.each do |line|
        expect(line).not_to include(email)
        expect(line).not_to include(EmailHasher.hash(email))
      end
    end

    it "requires authentication" do
      post "/api/v1/profile/verify_email", params: { email: email, code: "123456" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /api/v1/profile/send_verification_code" do
    let(:email) { "testuser@illinois.edu" }

    before do
      allow(ResendEmailService).to receive(:send_verification_code)
    end

    it "creates a hash-only verification code and sends the email" do
      post "/api/v1/profile/send_verification_code", params: { email: email }, headers: headers

      expect(response).to have_http_status(:ok)
      record = VerificationCode.for_email(email).sole
      expect(record.email).to be_nil
      expect(ResendEmailService).to have_received(:send_verification_code).with(email: email, code: record.code)
    end

    it "normalizes the email before hashing and sending" do
      post "/api/v1/profile/send_verification_code", params: { email: " TestUser@illinois.edu " }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(VerificationCode.for_email(email).count).to eq(1)
      expect(ResendEmailService).to have_received(:send_verification_code).with(email: email, code: anything)
    end

    it "returns 400 for non-illinois.edu email" do
      post "/api/v1/profile/send_verification_code", params: { email: "test@gmail.com" }, headers: headers

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["error"]["code"]).to eq("invalid_email")
    end

    it "returns 409 before sending when the email has already verified an account" do
      create(:verified_email, email: email)

      post "/api/v1/profile/send_verification_code", params: { email: email }, headers: headers

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["error"]["code"]).to eq("email_already_verified")
      expect(ResendEmailService).not_to have_received(:send_verification_code)
    end

    it "with purpose=release sends only for an already-verified email" do
      create(:verified_email, email: email)

      post "/api/v1/profile/send_verification_code", params: { email: email, purpose: "release" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(ResendEmailService).to have_received(:send_verification_code)
    end

    it "with purpose=release returns 404 for an unverified email" do
      post "/api/v1/profile/send_verification_code", params: { email: email, purpose: "release" }, headers: headers

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)["error"]["code"]).to eq("email_not_verified")
      expect(ResendEmailService).not_to have_received(:send_verification_code)
    end

    it "returns 422 for an unknown purpose" do
      post "/api/v1/profile/send_verification_code", params: { email: email, purpose: "hack" }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 429 when code was sent within 60 seconds" do
      create(:verification_code, email: email, created_at: 30.seconds.ago)

      post "/api/v1/profile/send_verification_code", params: { email: email }, headers: headers

      expect(response).to have_http_status(:too_many_requests)
    end

    it "allows resend after 60 seconds" do
      create(:verification_code, email: email, created_at: 61.seconds.ago)

      post "/api/v1/profile/send_verification_code", params: { email: email }, headers: headers

      expect(response).to have_http_status(:ok)
    end

    it "returns 500 when email delivery fails" do
      allow(ResendEmailService).to receive(:send_verification_code)
        .and_raise(ResendEmailService::DeliveryError, "邮件发送失败")

      post "/api/v1/profile/send_verification_code", params: { email: email }, headers: headers

      expect(response).to have_http_status(:internal_server_error)
    end
  end

  describe "POST /api/v1/profile/release_verified_email" do
    let(:email) { "testuser@illinois.edu" }

    before do
      Profile.find(user_id).update!(is_verified: true)
      create(:verified_email, email: email)
    end

    it "removes the hash and un-verifies the current account" do
      code = create(:verification_code, email: email)

      post "/api/v1/profile/release_verified_email", params: { email: email, code: code.code }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["is_verified"]).to eq(false)
      expect(VerifiedEmail.verified?(email)).to be false
      expect(VerificationCode.for_email(email).count).to eq(0)
    end

    it "lets the email verify a fresh account afterwards" do
      code = create(:verification_code, email: email)
      post "/api/v1/profile/release_verified_email", params: { email: email, code: code.code }, headers: headers

      new_code = create(:verification_code, email: email)
      post "/api/v1/profile/verify_email", params: { email: email, code: new_code.code }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(VerifiedEmail.verified?(email)).to be true
    end

    it "returns 400 for a wrong code and keeps the email verified" do
      create(:verification_code, email: email, code: "111111")

      post "/api/v1/profile/release_verified_email", params: { email: email, code: "999999" }, headers: headers

      expect(response).to have_http_status(:bad_request)
      expect(VerifiedEmail.verified?(email)).to be true
      expect(Profile.find(user_id).is_verified).to eq(true)
    end

    it "returns 404 for an email that never verified" do
      post "/api/v1/profile/release_verified_email", params: { email: "other@illinois.edu", code: "123456" }, headers: headers

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)["error"]["code"]).to eq("email_not_verified")
    end

    it "returns 400 for non-illinois.edu email" do
      post "/api/v1/profile/release_verified_email", params: { email: "x@gmail.com", code: "123456" }, headers: headers

      expect(response).to have_http_status(:bad_request)
    end

    it "is blocked for banned accounts (ban bypass via delete → re-register is closed)" do
      Profile.find(user_id).update!(banned_at: Time.current, ban_reason: "spam")
      code = create(:verification_code, email: email)

      post "/api/v1/profile/release_verified_email", params: { email: email, code: code.code }, headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(VerifiedEmail.verified?(email)).to be true
    end

    it "requires authentication" do
      post "/api/v1/profile/release_verified_email", params: { email: email, code: "123456" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /api/v1/profile/request_deletion" do
    it "sets scheduled_deletion_at to 30 days from now" do
      post "/api/v1/profile/request_deletion", headers: headers

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data["scheduled_deletion_at"]).to be_present

      deletion_date = Time.parse(data["scheduled_deletion_at"])
      expect(deletion_date).to be_within(1.minute).of(30.days.from_now)
    end

    it "returns 409 if already pending deletion" do
      Profile.find(user_id).update!(scheduled_deletion_at: 25.days.from_now)

      post "/api/v1/profile/request_deletion", headers: headers

      expect(response).to have_http_status(:conflict)
      data = JSON.parse(response.body)
      expect(data["error"]["code"]).to eq("already_pending")
    end

    it "is blocked for banned accounts" do
      Profile.find(user_id).update!(banned_at: Time.current, ban_reason: "spam")

      post "/api/v1/profile/request_deletion", headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(Profile.find(user_id).scheduled_deletion_at).to be_nil
    end

    it "requires authentication" do
      post "/api/v1/profile/request_deletion"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /api/v1/profile/cancel_deletion" do
    before do
      Profile.find(user_id).update!(scheduled_deletion_at: 25.days.from_now)
    end

    it "clears scheduled_deletion_at" do
      post "/api/v1/profile/cancel_deletion", headers: headers

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body)
      expect(data["scheduled_deletion_at"]).to be_nil
      expect(Profile.find(user_id).scheduled_deletion_at).to be_nil
    end

    it "returns 409 if not pending deletion" do
      Profile.find(user_id).update!(scheduled_deletion_at: nil)

      post "/api/v1/profile/cancel_deletion", headers: headers

      expect(response).to have_http_status(:conflict)
      data = JSON.parse(response.body)
      expect(data["error"]["code"]).to eq("not_pending")
    end

    it "requires authentication" do
      post "/api/v1/profile/cancel_deletion"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
