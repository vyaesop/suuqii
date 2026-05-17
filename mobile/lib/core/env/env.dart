class Env {
  static const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://suuqii.vercel.app',
  );

  static const sentryDsn = String.fromEnvironment('SENTRY_DSN');

  static const flavor = String.fromEnvironment('FLAVOR', defaultValue: 'prod');
}
