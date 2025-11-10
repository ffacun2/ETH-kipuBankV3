# KipuBankV3
KipuBankV3 es un contrato inteligente para una bóveda de ahorros (vault) descentralizada. Su función principal es aceptar depósitos de una amplia variedad de criptoactivos y **convertirlos automáticamente a USDC para almacenarlos**.

El contrato está construido sobre el protocolo **Uniswap V2** y está diseñado para mantener todos sus saldos internos y límites denominados en USDC.

### Funcionalidad Principal
El contrato opera como una bóveda que centraliza todo en USDC, independientemente de lo que se deposite.

1. **Bóveda de USDC:** Todo el valor dentro del contrato se almacena y contabiliza en USDC. Utiliza un ``mapping(address => uint256)`` para rastrear el saldo de USDC de cada usuario.

2. **Depósitos Flexibles:** Los usuarios pueden depositar fondos de tres maneras:

    - **ETH Nativo:** Usando la función ``depositEth``, el ETH del usuario se envía al contrato y se intercambia por USDC.

    - **Tokens ERC-20 (No USDC):** Usando la función ``deposit``, el usuario puede enviar cualquier token (como LINK, DAI, WBTC). El contrato recibe el token y lo intercambia por USDC.

    - **USDC Directo:** Si un usuario deposita USDC usando la función ``deposit``, se acredita directamente a su saldo sin necesidad de un intercambio.

3. **Retiros de USDC:** Los usuarios solo pueden retirar fondos en USDC, utilizando la función ``withdraw``.

### Características Clave
- **Integración con Uniswap V2:** El contrato utiliza el **Router de Uniswap V2** para ejecutar todos los intercambios (swaps) de forma automática. Esto le permite aceptar cualquier token que tenga un par de liquidez con USDC en Uniswap.

- **Límites de Capitalización:** El contrato impone dos límites inmutables (establecidos en el despliegue):

    - ``i_bankCapUSDC:`` El monto total de USDC que la bóveda puede almacenar.

    - ``i_withdrawalLimitUSDC:`` La cantidad máxima de USDC que un usuario puede retirar en una sola transacción.

- **Control de Acceso:** Utiliza el contrato ``Ownable`` de OpenZeppelin. El "dueño" (owner) es el único que puede ejecutar funciones administrativas, como el retiro de emergencia de fondos (``emergencyWithdraw``).

### Características de Seguridad
Para proteger a los usuarios durante las interacciones con un protocolo DeFi externo como Uniswap, se implementan varias medidas de seguridad:

- **Protección contra Slippage:** Las funciones de depósito (``deposit`` y ``depositEth``) requieren un parámetro ``_amountOutMin``. Esto asegura que la transacción solo se complete si el usuario recibe una cantidad de USDC igual o mayor a la que espera, protegiéndolo de la volatilidad del mercado.

- **Protección de Deadline:** Todas las funciones de depósito también requieren un ``_deadline``. Esto evita que una transacción quede "atascada" en la mempool y se ejecute mucho después a un precio desfavorable.

- **SafeERC20:**Todas las transferencias de tokens (depósitos, retiros e intercambios) se realizan utilizando la librería ``SafeERC20`` de OpenZeppelin para prevenir errores con tokens no estándar.

- **Bloqueo de receive y fallback:** Las funciones ``receive()`` y ``fallback()`` están deshabilitadas (``revert KipuBank__FallbackNotAllowed``). Esto es una medida de seguridad para forzar a los usuarios a utilizar las funciones de depósito correctas (``depositEth`` o ``deposit``), que incluyen las protecciones de slippage y deadline.