import 'api_client.dart';

// Missing, expired and inaccessible posts deliberately share one response.
// Never infer deletion or disclose which privacy condition caused a 404.
bool isPostUnavailable(Object? error) =>
    error is ApiException && error.statusCode == 404;

const unavailableCommentNotice =
    'This post is no longer available. You can copy your draft below.';
