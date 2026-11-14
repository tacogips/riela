/** Stable, non-secret reasons why a Monja base URL is rejected. */
export enum MonjaUrlPolicyRejectionKind {
  InvalidUrl = "invalid_url",
  UserInfoNotAllowed = "userinfo_not_allowed",
  QueryNotAllowed = "query_not_allowed",
  FragmentNotAllowed = "fragment_not_allowed",
  SchemeNotAllowed = "scheme_not_allowed",
  InsecureHostNotAllowed = "insecure_host_not_allowed",
}

export type MonjaUrlPolicyResult =
  | Readonly<{
      ok: true;
      value: Readonly<{
        normalizedBaseUrl: string;
        allowInsecureLocalhost: boolean;
      }>;
    }>
  | Readonly<{
      ok: false;
      error: Readonly<{ kind: MonjaUrlPolicyRejectionKind }>;
    }>;

const HTTP_LOOPBACK_HOSTNAMES = new Set<string>([
  "localhost",
  "127.0.0.1",
  "[::1]",
]);

function reject(kind: MonjaUrlPolicyRejectionKind): MonjaUrlPolicyResult {
  return { ok: false, error: { kind } };
}

/**
 * Classifies a base URL without performing DNS resolution or network I/O.
 *
 * HTTPS is always eligible. Plain HTTP is eligible only for a normalized,
 * exact loopback hostname; the caller must pass the derived boolean to the
 * SDK, which performs the final path-prefix and route-safety validation.
 */
export function evaluateMonjaBaseUrlPolicy(
  rawBaseUrl: string,
): MonjaUrlPolicyResult {
  let url: URL;
  try {
    url = new URL(rawBaseUrl);
  } catch {
    return reject(MonjaUrlPolicyRejectionKind.InvalidUrl);
  }

  if (url.username.length > 0 || url.password.length > 0) {
    return reject(MonjaUrlPolicyRejectionKind.UserInfoNotAllowed);
  }
  if (url.search.length > 0) {
    return reject(MonjaUrlPolicyRejectionKind.QueryNotAllowed);
  }
  if (url.hash.length > 0) {
    return reject(MonjaUrlPolicyRejectionKind.FragmentNotAllowed);
  }

  if (url.protocol === "https:") {
    return {
      ok: true,
      value: {
        normalizedBaseUrl: url.href,
        allowInsecureLocalhost: false,
      },
    };
  }
  if (url.protocol !== "http:") {
    return reject(MonjaUrlPolicyRejectionKind.SchemeNotAllowed);
  }
  if (!HTTP_LOOPBACK_HOSTNAMES.has(url.hostname)) {
    return reject(MonjaUrlPolicyRejectionKind.InsecureHostNotAllowed);
  }

  return {
    ok: true,
    value: {
      normalizedBaseUrl: url.href,
      allowInsecureLocalhost: true,
    },
  };
}
