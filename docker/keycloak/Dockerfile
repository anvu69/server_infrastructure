FROM quay.io/keycloak/keycloak:25.0.0 as builder

# Install custom providers

# Apple Social Identity Provider - https://github.com/klausbetz/apple-identity-provider-keycloak
ADD --chown=keycloak:keycloak https://github.com/klausbetz/apple-identity-provider-keycloak/releases/download/1.13.0/apple-identity-provider-1.13.0.jar /opt/keycloak/providers/apple-identity-provider-1.13.0.jar

# build optimized image
RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:25.0.0

COPY --from=builder /opt/keycloak/ /opt/keycloak/
WORKDIR /opt/keycloak

ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]