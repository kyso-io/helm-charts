// Minimal plugin to log the multi-semantic-release next version
function verifyRelease(pluginConfig, context) {
  if (context.nextRelease && context.nextRelease.version) {
    context.logger.log(`verifyRelease: NEXT_VERSION=${context.nextRelease.version}`);
  }
}
module.exports = {
  verifyRelease
}
