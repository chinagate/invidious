def generate_token(email, scopes, expire, key, db)
  session = "v1:#{Base64.urlsafe_encode(Random::Secure.random_bytes(32))}"
  PG_DB.exec("INSERT INTO session_ids VALUES ($1, $2, $3)", session, email, Time.now)

  token = {
    "session" => session,
    "scopes"  => scopes,
    "expire"  => expire,
  }

  if !expire
    token.delete("expire")
  end

  token["signature"] = sign_token(key, token)

  return token.to_json
end

def generate_response(session, scopes, key, db, expire = 6.hours, use_nonce = false)
  expire = Time.now + expire

  token = {
    "session" => session,
    "expire"  => expire.to_unix,
    "scopes"  => scopes,
  }

  if use_nonce
    nonce = Random::Secure.hex(16)
    db.exec("INSERT INTO nonces VALUES ($1, $2) ON CONFLICT DO NOTHING", nonce, expire)
    token["nonce"] = nonce
  end

  token["signature"] = sign_token(key, token)

  return token.to_json
end

def sign_token(key, hash)
  string_to_sign = [] of String

  hash.each do |key, value|
    if key == "signature"
      next
    end

    if value.is_a?(JSON::Any)
      case value
      when .as_a?
        value = value.as_a.map { |item| item.as_s }
      end
    end

    case value
    when Array
      string_to_sign << "#{key}=#{value.sort.join(",")}"
    when Tuple
      string_to_sign << "#{key}=#{value.to_a.sort.join(",")}"
    else
      string_to_sign << "#{key}=#{value}"
    end
  end

  string_to_sign = string_to_sign.sort.join("\n")
  return Base64.urlsafe_encode(OpenSSL::HMAC.digest(:sha256, key, string_to_sign)).strip
end

def validate_request(token, session, request, key, db, locale = nil)
  case token
  when String
    token = JSON.parse(URI.unescape(token)).as_h
  when JSON::Any
    token = token.as_h
  when Nil
    raise translate(locale, "Hidden field \"token\" is a required field")
  end

  if token["signature"] != sign_token(key, token)
    raise translate(locale, "Invalid signature")
  end

  if token["session"] != session
    raise translate(locale, "Erroneous token")
  end

  if token["nonce"]? && (nonce = db.query_one?("SELECT * FROM nonces WHERE nonce = $1", token["nonce"], as: {String, Time}))
    if nonce[1] > Time.now
      db.exec("UPDATE nonces SET expire = $1 WHERE nonce = $2", Time.new(1990, 1, 1), nonce[0])
    else
      raise translate(locale, "Erroneous token")
    end
  end

  scopes = token["scopes"].as_a.map { |v| v.as_s }
  scope = "#{request.method}:#{request.path.lchop("/api/v1/auth/").lstrip("/")}"

  if !scopes_include_scope(scopes, scope)
    raise translate(locale, "Invalid scope")
  end

  expire = token["expire"]?.try &.as_i
  if expire.try &.< Time.now.to_unix
    raise translate(locale, "Token is expired, please try again")
  end

  return {scopes, expire, token["signature"].as_s}
end

def scope_includes_scope(scope, subset)
  methods, endpoint = scope.split(":")
  methods = methods.split(";").map { |method| method.upcase }.reject { |method| method.empty? }.sort
  endpoint = endpoint.downcase

  subset_methods, subset_endpoint = subset.split(":")
  subset_methods = subset_methods.split(";").map { |method| method.upcase }.sort
  subset_endpoint = subset_endpoint.downcase

  if methods.empty?
    methods = %w(GET POST PUT HEAD DELETE PATCH OPTIONS)
  end

  if methods & subset_methods != subset_methods
    return false
  end

  if endpoint.ends_with?("*") && !subset_endpoint.starts_with? endpoint.rchop("*")
    return false
  end

  if !endpoint.ends_with?("*") && subset_endpoint != endpoint
    return false
  end

  return true
end

def scopes_include_scope(scopes, subset)
  scopes.each do |scope|
    if scope_includes_scope(scope, subset)
      return true
    end
  end

  return false
end
