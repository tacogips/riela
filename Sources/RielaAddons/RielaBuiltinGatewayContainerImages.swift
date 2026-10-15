/// Local images built from the pinned source by build-gateway-container.sh.
/// Registry images remain available through an explicit config.image override.
public enum RielaBuiltinGatewayContainerImages {
  public static let x = "riela-x-gateway:local"
  public static let gmail = "riela-gmail-gateway:local"
}
