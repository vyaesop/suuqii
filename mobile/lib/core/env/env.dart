class Env {
  static const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api.suuqii.app',
  );

  static const sentryDsn = String.fromEnvironment('SENTRY_DSN', defaultValue: '');

  static const flavor = String.fromEnvironment('FLAVOR', defaultValue: 'prod');
}
