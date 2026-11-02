# Patch script to fix MSVC compilation errors in google-cloud-cpp dependency.
# This script is executed via CMake -P during the FetchContent patch step.

macro (patch_file file_path search_str replace_str)
    if (EXISTS "${file_path}")
        file(READ "${file_path}" contents)
        string(REPLACE "\r\n" "\n" norm_search "${search_str}")
        string(REPLACE "\r\n" "\n" norm_replace "${replace_str}")
        string(FIND "${contents}" "${norm_search}" index)
        if (NOT index EQUAL -1)
            string(REPLACE "${norm_search}" "${norm_replace}" contents
                           "${contents}")
            file(WRITE "${file_path}" "${contents}")
            message(
                STATUS
                    "[google-cloud-cpp Patch] Successfully patched ${file_path}"
            )
        else ()
            message(
                STATUS
                    "[google-cloud-cpp Patch] ${file_path} is already patched or target string not found"
            )
        endif ()
    else ()
        message(
            FATAL_ERROR
                "[google-cloud-cpp Patch] Required file ${file_path} does not exist"
        )
    endif ()
endmacro ()

# Patch both affected files in the extracted source directory
patch_file("google/cloud/internal/rest_opentelemetry.cc"
           "std::string{kv.first}" "kv.first.name()")
patch_file("google/cloud/internal/tracing_rest_client.cc"
           "std::string{kv.first}" "kv.first.name()")

# Patch oauth2_regional_access_boundary_token_manager.h to fix MSVC __func__
# capture issue
set(search_target
    "    auto constexpr kLocation = __func__;
    auto pending_refresh_fn = [p = std::move(pending_refresh),
                               weak = weak_from_this(), request,
                               stub = iam_stub_,
                               retry_policy = retry_policy_->clone(),
                               backoff_policy = backoff_policy_->clone(),
                               options = options_]() mutable {")

set(replace_target
    "    auto pending_refresh_fn = [p = std::move(pending_refresh),
                               weak = weak_from_this(), request,
                               stub = iam_stub_,
                               retry_policy = retry_policy_->clone(),
                               backoff_policy = backoff_policy_->clone(),
                               options = options_]() mutable {
      auto constexpr kLocation = \"RefreshToken\";")

patch_file(
    "google/cloud/internal/oauth2_regional_access_boundary_token_manager.h"
    "${search_target}" "${replace_target}")

# Patch win32/sign_using_sha256.cc to match the 3-argument signature in
# sign_using_sha256.h
set(win32_sign_search "StatusOr<std::vector<std::uint8_t>> SignUsingSha256(
    std::string const& str, std::string const& pem_contents) {")

set(win32_sign_replace
    "StatusOr<std::vector<std::uint8_t>> SignUsingSha256(
    std::string const& str, std::string const& pem_contents,
    SignatureFormat /*format*/) {")

patch_file("google/cloud/internal/win32/sign_using_sha256.cc"
           "${win32_sign_search}" "${win32_sign_replace}")

# cmake-format: off
# Backport googleapis/google-cloud-cpp#16581:
# Support external_account_authorized_user credentials.
patch_file("google/cloud/internal/oauth2_external_account_credentials.h"
           "#include <memory>\n#include <optional>"
           "#include <memory>\n#include <mutex>\n#include <optional>")

set(ea_hdr_struct_search "struct WorkloadIdentityFederationInfo {
  std::string project_id;
  std::string pool_id;
};")

set(ea_hdr_struct_replace "struct WorkloadIdentityFederationInfo {
  std::string project_id;
  std::string pool_id;
};

struct ExternalAccountAuthorizedUserInfo {
  std::string client_id;
  std::string client_secret;
  std::string refresh_token;
};")

patch_file("google/cloud/internal/oauth2_external_account_credentials.h"
           "${ea_hdr_struct_search}" "${ea_hdr_struct_replace}")

set(ea_hdr_info_search
    "      identity_federation_info;
  bool IsWorkforceIdentityFederation() const;")

set(ea_hdr_info_replace
    "      identity_federation_info;
  std::optional<ExternalAccountAuthorizedUserInfo> authorized_user_info =
      std::nullopt;
  bool IsWorkforceIdentityFederation() const;")

patch_file("google/cloud/internal/oauth2_external_account_credentials.h"
           "${ea_hdr_info_search}" "${ea_hdr_info_replace}")

set(ea_hdr_cls_search
    "  StatusOr<AccessToken> GetTokenImpersonation(std::string const& access_token,
                                              internal::ErrorContext const& ec);

  ExternalAccountInfo info_;")

set(ea_hdr_cls_replace
    "  StatusOr<AccessToken> GetTokenImpersonation(std::string const& access_token,
                                              internal::ErrorContext const& ec);
  StatusOr<AccessToken> GetTokenAuthorizedUser(
      std::chrono::system_clock::time_point tp);

  mutable std::mutex mu_;
  ExternalAccountInfo info_;")

patch_file("google/cloud/internal/oauth2_external_account_credentials.h"
           "${ea_hdr_cls_search}" "${ea_hdr_cls_replace}")

patch_file(
    "google/cloud/internal/oauth2_external_account_credentials.cc"
    "#include \"google/cloud/internal/oauth2_external_account_credentials.h\""
    "#include \"google/cloud/internal/oauth2_external_account_credentials.h\"\n#include \"google/cloud/internal/base64_transforms.h\""
)

patch_file("google/cloud/internal/oauth2_external_account_credentials.cc"
           "#include <nlohmann/json.hpp>\n#include <regex>"
           "#include <nlohmann/json.hpp>\n#include <mutex>\n#include <regex>")

set(ea_cc_parse_search
    "  if (*type != \"external_account\") {
    return InvalidArgumentError(
        \"mismatched type (\" + *type + \") in external account configuration\",
        GCP_ERROR_INFO().WithContext(ec));
  }

  auto audience = ValidateStringField(json, \"audience\", \"credentials-file\", ec);
  if (!audience) return std::move(audience).status();
  auto identity_federation = IdentityFederationFromAudience(*audience);

  auto subject_token_type =
      ValidateStringField(json, \"subject_token_type\", \"credentials-file\", ec);
  if (!subject_token_type) return std::move(subject_token_type).status();
  auto token_url =
      ValidateStringField(json, \"token_url\", \"credentials-file\", ec);
  if (!token_url) return std::move(token_url).status();
  auto universe_domain = GetUniverseDomainFromCredentialsJson(json);
  if (!universe_domain) return std::move(universe_domain).status();")

set(ea_cc_parse_replace
    "  if (*type != \"external_account\" &&
      *type != \"external_account_authorized_user\") {
    return InvalidArgumentError(
        \"mismatched type (\" + *type + \") in external account configuration\",
        GCP_ERROR_INFO().WithContext(ec));
  }
  auto token_url =
      ValidateStringField(json, \"token_url\", \"credentials-file\", ec);
  if (!token_url) return std::move(token_url).status();
  auto universe_domain = GetUniverseDomainFromCredentialsJson(json);
  if (!universe_domain) return std::move(universe_domain).status();

  if (*type == \"external_account_authorized_user\") {
    StatusOr<std::string> client_id =
        ValidateStringField(json, \"client_id\", \"credentials-file\", ec);
    if (!client_id) return std::move(client_id).status();
    StatusOr<std::string> client_secret =
        ValidateStringField(json, \"client_secret\", \"credentials-file\", ec);
    if (!client_secret) return std::move(client_secret).status();
    StatusOr<std::string> refresh_token =
        ValidateStringField(json, \"refresh_token\", \"credentials-file\", ec);
    if (!refresh_token) return std::move(refresh_token).status();
    StatusOr<std::string> audience =
        ValidateStringField(json, \"audience\", \"credentials-file\", \"\", ec);
    if (!audience) return std::move(audience).status();
    std::variant<std::monostate, WorkforceIdentityFederationInfo,
                 WorkloadIdentityFederationInfo>
        identity_federation = IdentityFederationFromAudience(*audience);

    return ExternalAccountInfo{
        *std::move(audience),
        {},
        *std::move(token_url),
        {},
        std::nullopt,
        *std::move(universe_domain),
        std::nullopt,
        std::move(identity_federation),
        ExternalAccountAuthorizedUserInfo{*std::move(client_id),
                                          *std::move(client_secret),
                                          *std::move(refresh_token)}};
  }

  auto audience = ValidateStringField(json, \"audience\", \"credentials-file\", ec);
  if (!audience) return std::move(audience).status();
  auto identity_federation = IdentityFederationFromAudience(*audience);

  auto subject_token_type =
      ValidateStringField(json, \"subject_token_type\", \"credentials-file\", ec);
  if (!subject_token_type) return std::move(subject_token_type).status();")

patch_file("google/cloud/internal/oauth2_external_account_credentials.cc"
           "${ea_cc_parse_search}" "${ea_cc_parse_replace}")

set(ea_cc_gettoken_search
    "StatusOr<AccessToken> ExternalAccountCredentials::GetToken(
    std::chrono::system_clock::time_point tp) {
  auto subject_token = (info_.token_source)(client_factory_, options_);")

set(ea_cc_gettoken_replace
    "StatusOr<AccessToken> ExternalAccountCredentials::GetToken(
    std::chrono::system_clock::time_point tp) {
  if (info_.authorized_user_info.has_value()) {
    return GetTokenAuthorizedUser(tp);
  }
  auto subject_token = (info_.token_source)(client_factory_, options_);")

patch_file("google/cloud/internal/oauth2_external_account_credentials.cc"
           "${ea_cc_gettoken_search}" "${ea_cc_gettoken_replace}")

set(ea_cc_authuser_search
    "  return ParseGenerateAccessTokenResponse(**response, ec);
}

GOOGLE_CLOUD_CPP_INLINE_NAMESPACE_END")

set(ea_cc_authuser_replace
    "  return ParseGenerateAccessTokenResponse(**response, ec);
}

StatusOr<AccessToken> ExternalAccountCredentials::GetTokenAuthorizedUser(
    std::chrono::system_clock::time_point tp) {
  std::string current_refresh_token;
  {
    std::lock_guard<std::mutex> lk(mu_);
    current_refresh_token = info_.authorized_user_info->refresh_token;
  }
  internal::Base64Encoder encoder;
  for (unsigned char const c :
       absl::StrCat(info_.authorized_user_info->client_id, \":\",
                    info_.authorized_user_info->client_secret)) {
    encoder.PushBack(c);
  }
  rest_internal::RestRequest request =
      rest_internal::RestRequest(info_.token_url)
          .AddHeader(\"content-type\", \"application/x-www-form-urlencoded\")
          .AddHeader(\"Authorization\",
                     absl::StrCat(\"Basic \", std::move(encoder).FlushAndPad()));

  std::vector<std::pair<std::string, std::string>> form_data = {
      {\"grant_type\", \"refresh_token\"},
      {\"refresh_token\", std::move(current_refresh_token)},
  };

  std::unique_ptr<rest_internal::RestClient> client = client_factory_(options_);
  rest_internal::RestContext unused;
  StatusOr<std::unique_ptr<rest_internal::RestResponse>> response =
      client->Post(unused, request, form_data);
  if (!response) return std::move(response).status();
  if (IsHttpError(**response)) return AsStatus(std::move(**response));
  StatusOr<std::string> payload =
      rest_internal::ReadAll(std::move(**response).ExtractPayload());
  if (!payload) return std::move(payload).status();

  internal::ErrorContext const ec(
      internal::ErrorContext::Container{{\"token_url\", info_.token_url}});

  nlohmann::json access = nlohmann::json::parse(*payload, nullptr, false);
  if (!access.is_object()) {
    return InvalidArgumentError(
        \"token refresh response cannot be parsed as JSON object\",
        GCP_ERROR_INFO().WithContext(ec));
  }
  StatusOr<std::string> token =
      ValidateStringField(access, \"access_token\", \"token-refresh-response\", ec);
  if (!token) return std::move(token).status();
  StatusOr<std::int32_t> expires_in =
      ValidateIntField(access, \"expires_in\", \"token-refresh-response\", ec);
  if (!expires_in) return std::move(expires_in).status();
  StatusOr<std::string> new_refresh_token = ValidateStringField(
      access, \"refresh_token\", \"token-refresh-response\", \"\", ec);
  if (!new_refresh_token) return std::move(new_refresh_token).status();
  if (!new_refresh_token->empty()) {
    std::lock_guard<std::mutex> lk(mu_);
    info_.authorized_user_info->refresh_token = *std::move(new_refresh_token);
  }
  return AccessToken{*std::move(token), tp + std::chrono::seconds(*expires_in)};
}

GOOGLE_CLOUD_CPP_INLINE_NAMESPACE_END")

patch_file("google/cloud/internal/oauth2_external_account_credentials.cc"
           "${ea_cc_authuser_search}" "${ea_cc_authuser_replace}")

patch_file(
    "google/cloud/internal/oauth2_google_credentials.cc"
    "  if (cred_type == \"external_account\") {"
    "  if (cred_type == \"external_account\" ||\n      cred_type == \"external_account_authorized_user\") {"
)

set(grpc_ea_search
    "    void visit(ExternalAccountConfig const& cfg) override {
      grpc::SslCredentialsOptions ssl_options;
      auto cainfo = LoadCAInfo(options);
      if (cainfo) ssl_options.pem_root_certs = std::move(*cainfo);
      result = std::make_unique<GrpcChannelCredentialsAuthentication>(
          grpc::CompositeChannelCredentials(
              grpc::SslCredentials(ssl_options),
              GrpcExternalAccountCredentials(cfg)));
    }")

set(grpc_ea_replace
    "    void visit(ExternalAccountConfig const& cfg) override {
      auto external_account_creds = GrpcExternalAccountCredentials(cfg);
      if (!external_account_creds) {
        result = std::make_unique<GrpcErrorCredentialsAuthentication>(
            ErrorCredentialsConfig{InvalidArgumentError(
                \"Error creating grpc::ExternalAccountCredentials\",
                GCP_ERROR_INFO())});
        return;
      }
      grpc::SslCredentialsOptions ssl_options;
      auto cainfo = LoadCAInfo(options);
      if (cainfo) ssl_options.pem_root_certs = std::move(*cainfo);
      result = std::make_unique<GrpcChannelCredentialsAuthentication>(
          grpc::CompositeChannelCredentials(grpc::SslCredentials(ssl_options),
                                            std::move(external_account_creds)));
    }")

patch_file("google/cloud/internal/unified_grpc_credentials.cc"
           "${grpc_ea_search}" "${grpc_ea_replace}")
# cmake-format: on
