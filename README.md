# KipuBankV3

`KipuBankV3` es un contrato inteligente para una bóveda de ahorros (vault) descentralizada. Su función principal es aceptar depósitos de una amplia variedad de criptoactivos y **convertirlos automáticamente a USDC** para almacenarlos.

El contrato está construido sobre el protocolo **Uniswap V2** y está diseñado para mantener todos sus saldos internos y límites denominados en USDC.

---

## Funcionalidad Principal

El contrato opera como una bóveda que centraliza todo en USDC, independientemente de lo que se deposite.

1.  **Bóveda de USDC:** Todo el valor dentro del contrato se almacena y contabiliza en USDC. Utiliza un `mapping(address => uint256)` para rastrear el saldo de USDC de cada usuario.

2.  **Depósitos Flexibles:** Los usuarios pueden depositar fondos de tres maneras:
    * **ETH Nativo:** Usando la función `depositEth`, el ETH del usuario se envía al contrato y se intercambia por USDC.
    * **Tokens ERC-20 (No USDC):** Usando la función `deposit`, el usuario puede enviar cualquier token (como LINK, DAI, WBTC). El contrato recibe el token y lo intercambia por USDC.
    * **USDC Directo:** Si un usuario deposita USDC usando la función `deposit`, se acredita directamente a su saldo sin necesidad de un intercambio.

3.  **Retiros de USDC:** Los usuarios solo pueden retirar fondos en USDC, utilizando la función `withdraw`.

---

##  Características Clave

* **Integración con Uniswap V2:** El contrato utiliza el **Router de Uniswap V2** para ejecutar todos los intercambios (swaps) de forma automática. Esto le permite aceptar cualquier token que tenga un par de liquidez con USDC en Uniswap.

* **Límites de Capitalización:** El contrato impone dos límites inmutables (establecidos en el despliegue):
    * `i_bankCapUSDC`: El monto total de USDC que la bóveda puede almacenar.
    * `i_withdrawalLimitUSDC`: La cantidad máxima de USDC que un usuario puede retirar en una sola transacción.

* **Control de Acceso:** Utiliza el contrato `Ownable` de OpenZeppelin. El "dueño" (owner) es el único que puede ejecutar funciones administrativas, como el retiro de emergencia de fondos (`emergencyWithdraw`).

---

## Decisiones de Diseño y Trade-offs

1.  **Dependencia de Uniswap V2:**
    * **Beneficio:** El contrato es *permissionless*. No requiere que un administrador "autorice" nuevos tokens. Cualquier activo con liquidez en Uniswap V2 puede ser depositado.
    * **Trade-off:** El contrato depende 100% de que el router de Uniswap V2 esté operativo y que exista liquidez para el par del token depositado (ej. `LINK/USDC`). Si la liquidez es baja, los usuarios experimentarán un *slippage* (deslizamiento de precio) muy alto.

2.  **Costo de Gas en Depósitos:**
    * **Trade-off:** Los depósitos que no son de USDC (`deposit` con un token o `depositEth`) son **significativamente más caros en gas** que un simple `transfer`. Cada depósito de este tipo debe ejecutar:
        1.  Un `safeTransferFrom` (para recibir el token).
        2.  Un `approve` (para permitir que Uniswap gaste el token).
        3.  Un `swap` (la operación de intercambio).
    * El depósito de USDC directo sigue siendo muy barato en gas.

3.  **Protección de `deadline` y `amountOutMin`:**
    * **Beneficio:** Se incluyen parámetros de seguridad (`_deadline` y `_amountOutMin`) en todas las funciones de depósito. Esto es **crucial** para proteger a los usuarios de la volatilidad del mercado (*slippage*) y de transacciones "atascadas" (*deadline*).
    * **Trade-off:** La lógica del *frontend* (la interfaz de usuario) se vuelve más compleja, ya que debe calcular estos valores para el usuario.

4.  **Validación del Límite del Banco (Bank Cap):**
    * **Implementación:** Para `depositEth`, el contrato *primero* estima el USDC a recibir (`getAmountsOut`) y *luego* valida el límite con esa estimación. Para `deposit` de tokens, *primero* hace el swap y *luego* valida el límite con el monto real.
    * **Trade-off:** El enfoque de `depositEth` es más rápido pero tiene un riesgo teórico de *slippage positivo* (recibir más USDC del estimado) que podría hacer que el banco supere su límite por una pequeña cantidad. El enfoque de `deposit` es más seguro para el límite del banco, pero gasta más gas en una transacción fallida (ya que revierte *después* del swap).

5.  **Bloqueo de `fallback` y `receive`:**
    * **Decisión:** Las funciones `receive()` y `fallback()` están deshabilitadas (`revert`).
    * **Razón:** Es una medida de seguridad para forzar a los usuarios a usar `depositEth`. Si `receive` estuviera habilitado, un usuario podría enviar ETH al contrato por accidente sin los parámetros de seguridad (`_amountOutMin`, `_deadline`), resultando en un swap fallido o fondos perdidos.

---

## Instrucciones de Despliegue e Interacción

### Dependencias

Asegúrate de tener instaladas las librerías de Uniswap y OpenZeppelin. Con Foundry o Hardhat, esto se hace con:

```bash
forge install uniswap/v2-periphery
forge install uniswap/v2-core
forge install OpenZeppelin/openzeppelin-contracts
```

Para desplegar, necesitas las direcciones reales de los contratos en la red de Sepolia.

**Argumentos del Constructor:**

- ``_bankCapUSDC``: ``1000000000000`` (Simula $1,000,000. 1M * 10^6).

- ``_withdrawalLimitUSDC``: ``5000000000`` (Simula $5,000. 5k * 10^6).

- ``_router`` (Router V2 Sepolia): ``0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008``

- ``_usdc`` (USDC Sepolia): ``0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8``

- ``_weth`` (WETH Sepolia): ``0x7b79995e5f793A07Bc00c21412e50Ea00A7Saa9i``

#### Comando (Foundry):

``` bash
forge create src/KipuBank.sol:KipuBank \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --constructor-args 1000000000000 5000000000 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8 0x7b79995e5f793A07Bc00c21412e50Ea00A7Saa9i \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    --verify
```

#### Interacción
1. **Depositar ETH (ej. 0.1 ETH)**

    - ``_amountOutMin``: ``1`` (o un valor calculado por el frontend).

    - ``_deadline``: ``block.timestamp + 1800`` (30 minutos desde ahora).

    - **Acción**: Llamar a ``depositEth(1, 17xxxxxxx)`` enviando 0.1 ETH (0.1e18 wei) en la transacción.

2. **Depositar un Token ERC20 (ej. 10 LINK)**

    - ``_token``: ``0x779877A7B0D9E8603169DdbD7836e478b4624789`` (Dirección de LINK en Sepolia).

    - ``_amount``: ``10000000000000000000`` (10 * 10^18).

    - ``_amountOutMin``: ``1``.

    - ``_deadline``: ``block.timestamp + 1800``.

    - **Acción (Paso 1)**: Llamar a ``approve()`` en el contrato de LINK para aprobar que KipuBank gaste 10 LINK.

    - **Acción (Paso 2):** Llamar a ``deposit(0x779..., 10e18, 1, 17xxxxxxx)`` en el contrato de KipuBank.

3. **Depositar USDC (ej. 100 USDC)**

    - ``_token``: ``0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8`` (Dirección de USDC en Sepolia).

    - ``_amount``: ``100000000`` (100 * 10^6, ¡USDC solo tiene 6 decimales!).

    - ``_amountOutMin``: ``0`` (ignorado, pero se debe pasar).

    - ``_deadline``: ``block.timestamp + 1800``.

    - **Acción (Paso 1):** Llamar a ``approve()`` en el contrato de USDC para aprobar 100 USDC.

    - **Acción (Paso 2):** Llamar a ``deposit(0x94a..., 100e6, 0, 17xxxxxxx)`` en el contrato de KipuBank.

4. **Retirar Fondos (ej. 50 USDC)**

    - ``_amountUSDC``: ``50000000`` (50 * 10^6).

    - **Acción**: Llamar a ``withdraw(50000000)``.