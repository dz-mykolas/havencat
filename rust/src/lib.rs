pub mod api;
pub mod conversations;
mod frb_generated;
pub mod web_retrieval;

#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_com_example_havencat_HavenCatApplication_initializePlatformVerifier<
    'local,
>(
    mut unowned_env: jni::EnvUnowned<'local>,
    _application: jni::objects::JObject<'local>,
    context: jni::objects::JObject<'local>,
) {
    let outcome =
        unowned_env.with_env(|env| rustls_platform_verifier::android::init_with_env(env, context));
    outcome.resolve::<jni::errors::ThrowRuntimeExAndDefault>();
}
