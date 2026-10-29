/* =====================================================================
   02_sp_VenderBoleto.sql  -  E2.3 Procedimiento de venta correcto
   ---------------------------------------------------------------------
   JUSTIFICACION DEL BLOQUEO
   - UPDLOCK : la verificacion toma un bloqueo de ACTUALIZACION (no solo
               compartido). Dos sesiones no pueden tener U sobre el mismo
               rango a la vez, asi que la segunda ESPERA. Evita ademas el
               deadlock de conversion S->X que ocurriria con solo HOLDLOCK.
   - HOLDLOCK: equivale a SERIALIZABLE solo para esa sentencia. Mantiene el
               bloqueo hasta COMMIT y, al usar un indice, bloquea el RANGO de
               llaves aunque la fila aun no exista (evita el fantasma).
   - Se prefiere a SET TRANSACTION ISOLATION LEVEL SERIALIZABLE porque ese
     nivel afectaria TODAS las lecturas del procedimiento (Clientes,
     Asientos, Viajes) y bloquearia mas de lo necesario.
   - El indice unico filtrado de 01_integridad.sql es la ultima red de
     seguridad: aun si alguien omite el procedimiento, la BD rechaza la doble venta.
   Codigos de error: 50001 canal, 50002 metodo, 50003 viaje inexistente,
   50004 viaje no programado, 50005 asiento inexistente, 50006 cliente
   inexistente, 50007 asiento ya vendido.
   ===================================================================== */
USE BusRD;
GO
CREATE OR ALTER PROCEDURE dbo.sp_VenderBoleto
    @ViajeID        INT,
    @NumeroAsiento  INT,
    @ClienteID      INT,
    @Canal          VARCHAR(10),
    @Metodo         VARCHAR(15),
    @BoletoID       INT OUTPUT,
    @SimularDemora  BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;      -- cualquier error de ejecucion aborta y marca la transaccion

    DECLARE @AutobusID INT, @EstadoViaje VARCHAR(15), @Precio DECIMAL(10,2);
    SET @BoletoID = NULL;

    BEGIN TRY
        -- Validaciones que no necesitan leer tablas
        IF @Canal  IS NULL OR @Canal  NOT IN ('Taquilla','Web')
            THROW 50001, 'Canal invalido. Use Taquilla o Web.', 1;
        IF @Metodo IS NULL OR @Metodo NOT IN ('Efectivo','Tarjeta','Transferencia')
            THROW 50002, 'Metodo de pago invalido.', 1;

        BEGIN TRANSACTION;

            -- Viaje (y su precio base)
            SELECT @AutobusID  = v.AutobusID,
                   @EstadoViaje = v.Estado,
                   @Precio     = r.PrecioBase
            FROM dbo.Viajes v
            JOIN dbo.Rutas  r ON r.RutaID = v.RutaID
            WHERE v.ViajeID = @ViajeID;

            IF @AutobusID IS NULL
                THROW 50003, 'El viaje no existe.', 1;
            IF @EstadoViaje <> 'Programado'
                THROW 50004, 'El viaje no esta Programado.', 1;

            -- El asiento debe existir en el autobus de ESE viaje
            IF NOT EXISTS (SELECT 1 FROM dbo.Asientos
                           WHERE AutobusID = @AutobusID AND NumeroAsiento = @NumeroAsiento)
                THROW 50005, 'El asiento no existe en el autobus del viaje.', 1;

            IF NOT EXISTS (SELECT 1 FROM dbo.Clientes WHERE ClienteID = @ClienteID)
                THROW 50006, 'El cliente no existe.', 1;

            -- *** PUNTO CRITICO: verificar y reservar el asiento de forma atomica ***
            IF EXISTS (SELECT 1
                       FROM dbo.Boletos WITH (UPDLOCK, HOLDLOCK)
                       WHERE ViajeID = @ViajeID
                         AND NumeroAsiento = @NumeroAsiento
                         AND Estado = 'Activo')
                THROW 50007, 'El asiento ya esta vendido.', 1;

            -- Demo: simula el tiempo del cobro CON el bloqueo ya tomado
            IF @SimularDemora = 1
                WAITFOR DELAY '00:00:10';

            INSERT dbo.Boletos(ViajeID, NumeroAsiento, ClienteID, FechaVenta, Canal, Precio, Estado)
            VALUES (@ViajeID, @NumeroAsiento, @ClienteID, SYSDATETIME(), @Canal, @Precio, 'Activo');

            SET @BoletoID = SCOPE_IDENTITY();

            INSERT dbo.Pagos(BoletoID, Monto, Metodo, FechaPago)
            VALUES (@BoletoID, @Precio, @Metodo, SYSDATETIME());

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SET @BoletoID = NULL;
        THROW;      -- relanza el error original al llamador
    END CATCH
END
GO
