/* =====================================================================
   06_indices_y_consultas_optimizadas.sql  -  E3. Optimizacion (Unidad II)
   ANTES DE EMPEZAR en SSMS: activar "Incluir plan de ejecucion real" (Ctrl+M)
   y mirar la pestana Mensajes (lecturas logicas y tiempos).
   Secciones: A) linea base  B) indices  C) consultas optimizadas
              D) mismo resultado  E) efecto de los indices en sp_VenderBoleto
   CONFIGURACION: @ViajeID = viaje asignado; @Grupo = numero de grupo
   (cedula = cliente numero Grupo x 1000, formato '402' + 8 digitos).
   ===================================================================== */
USE BusRD;
GO

/* Dejar el esquema en estado "sin indices de apoyo" para medir la linea base.
   El indice unico filtrado se DESHABILITA solo para esta medicion y se
   reconstruye en la seccion B (es el que resuelve C1). */
DROP INDEX IF EXISTS IX_Boletos_ClienteID        ON dbo.Boletos;
DROP INDEX IF EXISTS IX_Boletos_Estado_FechaVenta ON dbo.Boletos;
DROP INDEX IF EXISTS IX_Pagos_BoletoID           ON dbo.Pagos;
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'UX_Boletos_Viaje_Asiento_Activo'
             AND object_id = OBJECT_ID('dbo.Boletos') AND is_disabled = 0)
    ALTER INDEX UX_Boletos_Viaje_Asiento_Activo ON dbo.Boletos DISABLE;
GO
-- Solo en ambiente de pruebas: cache fria para medir lecturas fisicas comparables
CHECKPOINT;
DBCC DROPCLEANBUFFERS;
GO

/* =====================================================================
   A) LINEA BASE  (consultas ORIGINALES, sin tocar)
   ===================================================================== */
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

/* ---- C1 original ---- */
DECLARE @ViajeID INT = 16000;                       -- <<< viaje asignado
SELECT s.NumeroAsiento, s.Ubicacion
FROM dbo.Viajes v
JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.ViajeID = @ViajeID
  AND s.NumeroAsiento NOT IN (SELECT b.NumeroAsiento
                              FROM dbo.Boletos b
                              WHERE b.ViajeID = @ViajeID
                                AND b.Estado = 'Activo')
ORDER BY s.NumeroAsiento;
GO

/* ---- C2 original ---- */
DECLARE @Grupo INT = 1;                             -- <<< numero de grupo
DECLARE @Cedula CHAR(11) = '402' + RIGHT('00000000' + CAST(@Grupo * 1000 AS VARCHAR(8)), 8);
SELECT c.Nombre, c.Apellido, r.Origen, r.Destino,
       v.FechaSalida, b.NumeroAsiento, b.Precio, b.Estado
FROM dbo.Clientes c
JOIN dbo.Boletos b ON b.ClienteID = c.ClienteID
JOIN dbo.Viajes  v ON v.ViajeID   = b.ViajeID
JOIN dbo.Rutas   r ON r.RutaID    = v.RutaID
WHERE LTRIM(RTRIM(c.Cedula)) = @Cedula
ORDER BY v.FechaSalida DESC;
GO

/* ---- C3 original ---- */
SELECT r.Origen, r.Destino, MONTH(b.FechaVenta) AS Mes,
       COUNT(*) AS Boletos, SUM(p.Monto) AS Ingresos
FROM dbo.Boletos b
JOIN dbo.Pagos  p ON p.BoletoID = b.BoletoID
JOIN dbo.Viajes v ON v.ViajeID  = b.ViajeID
JOIN dbo.Rutas  r ON r.RutaID   = v.RutaID
WHERE YEAR(b.FechaVenta) = 2025
  AND b.Estado = 'Activo'
GROUP BY r.Origen, r.Destino, MONTH(b.FechaVenta)
ORDER BY r.Origen, r.Destino, Mes;
GO

/* DIAGNOSTICO ESPERADO (anotar en el informe con la captura del plan):
   C1: Clustered Index Scan de Boletos (no hay indice por ViajeID) + NOT IN
       (anti-semi join con tabla spool/null check).
   C2: LTRIM(RTRIM(Cedula)) = ... no es SARGABLE -> scan de Clientes; y
       Boletos se recorre completo (Clustered Index Scan) porque no existe
       indice por ClienteID.
   C3: YEAR(FechaVenta) = 2025 no es SARGABLE -> scan de Boletos; Pagos se
       recorre completo (no hay indice por BoletoID) + Sort/Hash Aggregate. */

/* =====================================================================
   B) INDICES
   ===================================================================== */
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- C1: el indice unico filtrado de E1 YA es el indice ideal:
--     clave (ViajeID, NumeroAsiento) -> seek por viaje y devuelve los asientos
--     ocupados SIN tocar la tabla (cubre la consulta); el filtro
--     Estado='Activo' coincide con el predicado, asi que solo contiene lo necesario.
ALTER INDEX UX_Boletos_Viaje_Asiento_Activo ON dbo.Boletos REBUILD;
GO

-- C2: busqueda de boletos de un cliente. Clave ClienteID (igualdad);
--     INCLUDE con las columnas que el SELECT necesita -> sin Key Lookup.
CREATE NONCLUSTERED INDEX IX_Boletos_ClienteID
    ON dbo.Boletos(ClienteID)
    INCLUDE (ViajeID, NumeroAsiento, Precio, Estado);
-- (la busqueda por Cedula ya usa UQ_Clientes_Cedula creado en E1)
GO

-- C3: clave (Estado, FechaVenta): igualdad primero y rango despues -> seek
--     exacto del ano 2025 de boletos activos. INCLUDE ViajeID para el join.
--     BoletoID viaja siempre porque es la clave del indice agrupado.
CREATE NONCLUSTERED INDEX IX_Boletos_Estado_FechaVenta
    ON dbo.Boletos(Estado, FechaVenta)
    INCLUDE (ViajeID);

-- C3: el join con Pagos por BoletoID; INCLUDE Monto evita ir a la tabla.
--     Ademas respalda la llave foranea FK_Pagos_Boletos.
CREATE NONCLUSTERED INDEX IX_Pagos_BoletoID
    ON dbo.Pagos(BoletoID)
    INCLUDE (Monto);
GO
CHECKPOINT;
DBCC DROPCLEANBUFFERS;
GO

/* =====================================================================
   C) CONSULTAS OPTIMIZADAS
   ===================================================================== */
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO

/* ---- C1 optimizada: NOT EXISTS (misma semantica: NumeroAsiento es NOT NULL) ---- */
DECLARE @ViajeID INT = 16000;                       -- <<< viaje asignado
SELECT s.NumeroAsiento, s.Ubicacion
FROM dbo.Viajes v
JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.ViajeID = @ViajeID
  AND NOT EXISTS (SELECT 1
                  FROM dbo.Boletos b
                  WHERE b.ViajeID = @ViajeID
                    AND b.NumeroAsiento = s.NumeroAsiento
                    AND b.Estado = 'Activo')
ORDER BY s.NumeroAsiento;
GO

/* ---- C2 optimizada: comparacion directa (sargable) ---- */
DECLARE @Grupo INT = 1;                             -- <<< numero de grupo
DECLARE @Cedula CHAR(11) = '402' + RIGHT('00000000' + CAST(@Grupo * 1000 AS VARCHAR(8)), 8);
SELECT c.Nombre, c.Apellido, r.Origen, r.Destino,
       v.FechaSalida, b.NumeroAsiento, b.Precio, b.Estado
FROM dbo.Clientes c
JOIN dbo.Boletos b ON b.ClienteID = c.ClienteID
JOIN dbo.Viajes  v ON v.ViajeID   = b.ViajeID
JOIN dbo.Rutas   r ON r.RutaID    = v.RutaID
WHERE c.Cedula = @Cedula
ORDER BY v.FechaSalida DESC;
GO

/* ---- C3 optimizada: rango de fechas en lugar de YEAR() ---- */
SELECT r.Origen, r.Destino, MONTH(b.FechaVenta) AS Mes,
       COUNT(*) AS Boletos, SUM(p.Monto) AS Ingresos
FROM dbo.Boletos b
JOIN dbo.Pagos  p ON p.BoletoID = b.BoletoID
JOIN dbo.Viajes v ON v.ViajeID  = b.ViajeID
JOIN dbo.Rutas  r ON r.RutaID   = v.RutaID
WHERE b.FechaVenta >= '2025-01-01' AND b.FechaVenta < '2026-01-01'
  AND b.Estado = 'Activo'
GROUP BY r.Origen, r.Destino, MONTH(b.FechaVenta)
ORDER BY r.Origen, r.Destino, Mes;
GO

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

/* TABLA COMPARATIVA (completar con los valores de la pestana Mensajes):
   | Consulta | Lecturas logicas antes | despues | CPU ms antes | despues | Operador costoso antes -> despues |
   | C1       |                        |         |              |         | Clustered Index Scan -> Index Seek |
   | C2       |                        |         |              |         | Scan Clientes/Boletos -> Seek + sin Key Lookup |
   | C3       |                        |         |              |         | Scan Boletos y Pagos -> Index Seek por rango |
*/

/* =====================================================================
   D) COMPROBAR QUE EL RESULTADO ES IDENTICO (EXCEPT en ambos sentidos = 0)
   ===================================================================== */
DECLARE @ViajeID INT = 16000;                       -- <<< viaje asignado
DECLARE @Grupo   INT = 1;                           -- <<< numero de grupo
DECLARE @Cedula  CHAR(11) = '402' + RIGHT('00000000' + CAST(@Grupo * 1000 AS VARCHAR(8)), 8);

-- C1
SELECT s.NumeroAsiento, s.Ubicacion INTO #c1o
FROM dbo.Viajes v JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.ViajeID = @ViajeID
  AND s.NumeroAsiento NOT IN (SELECT b.NumeroAsiento FROM dbo.Boletos b
                              WHERE b.ViajeID = @ViajeID AND b.Estado = 'Activo');
SELECT s.NumeroAsiento, s.Ubicacion INTO #c1n
FROM dbo.Viajes v JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.ViajeID = @ViajeID
  AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b
                  WHERE b.ViajeID = @ViajeID AND b.NumeroAsiento = s.NumeroAsiento AND b.Estado = 'Activo');

-- C2
SELECT c.Nombre, c.Apellido, r.Origen, r.Destino, v.FechaSalida, b.NumeroAsiento, b.Precio, b.Estado INTO #c2o
FROM dbo.Clientes c JOIN dbo.Boletos b ON b.ClienteID = c.ClienteID
JOIN dbo.Viajes v ON v.ViajeID = b.ViajeID JOIN dbo.Rutas r ON r.RutaID = v.RutaID
WHERE LTRIM(RTRIM(c.Cedula)) = @Cedula;
SELECT c.Nombre, c.Apellido, r.Origen, r.Destino, v.FechaSalida, b.NumeroAsiento, b.Precio, b.Estado INTO #c2n
FROM dbo.Clientes c JOIN dbo.Boletos b ON b.ClienteID = c.ClienteID
JOIN dbo.Viajes v ON v.ViajeID = b.ViajeID JOIN dbo.Rutas r ON r.RutaID = v.RutaID
WHERE c.Cedula = @Cedula;

-- C3
SELECT r.Origen, r.Destino, MONTH(b.FechaVenta) AS Mes, COUNT(*) AS Boletos, SUM(p.Monto) AS Ingresos INTO #c3o
FROM dbo.Boletos b JOIN dbo.Pagos p ON p.BoletoID = b.BoletoID
JOIN dbo.Viajes v ON v.ViajeID = b.ViajeID JOIN dbo.Rutas r ON r.RutaID = v.RutaID
WHERE YEAR(b.FechaVenta) = 2025 AND b.Estado = 'Activo'
GROUP BY r.Origen, r.Destino, MONTH(b.FechaVenta);
SELECT r.Origen, r.Destino, MONTH(b.FechaVenta) AS Mes, COUNT(*) AS Boletos, SUM(p.Monto) AS Ingresos INTO #c3n
FROM dbo.Boletos b JOIN dbo.Pagos p ON p.BoletoID = b.BoletoID
JOIN dbo.Viajes v ON v.ViajeID = b.ViajeID JOIN dbo.Rutas r ON r.RutaID = v.RutaID
WHERE b.FechaVenta >= '2025-01-01' AND b.FechaVenta < '2026-01-01' AND b.Estado = 'Activo'
GROUP BY r.Origen, r.Destino, MONTH(b.FechaVenta);

SELECT 'C1' AS Consulta,
       (SELECT COUNT(*) FROM #c1o) AS FilasOriginal, (SELECT COUNT(*) FROM #c1n) AS FilasNueva,
       (SELECT COUNT(*) FROM (SELECT * FROM #c1o EXCEPT SELECT * FROM #c1n) x) AS SoloEnOriginal,
       (SELECT COUNT(*) FROM (SELECT * FROM #c1n EXCEPT SELECT * FROM #c1o) x) AS SoloEnNueva
UNION ALL
SELECT 'C2', (SELECT COUNT(*) FROM #c2o), (SELECT COUNT(*) FROM #c2n),
       (SELECT COUNT(*) FROM (SELECT * FROM #c2o EXCEPT SELECT * FROM #c2n) x),
       (SELECT COUNT(*) FROM (SELECT * FROM #c2n EXCEPT SELECT * FROM #c2o) x)
UNION ALL
SELECT 'C3', (SELECT COUNT(*) FROM #c3o), (SELECT COUNT(*) FROM #c3n),
       (SELECT COUNT(*) FROM (SELECT * FROM #c3o EXCEPT SELECT * FROM #c3n) x),
       (SELECT COUNT(*) FROM (SELECT * FROM #c3n EXCEPT SELECT * FROM #c3o) x);
-- Esperado: filas iguales y 0 / 0 en todas.

-- Justificacion de la reescritura de C2: la cedula no tiene espacios sobrantes
SELECT COUNT(*) AS CedulasConEspacios                    -- esperado: 0
FROM dbo.Clientes WHERE Cedula <> LTRIM(RTRIM(Cedula));
GO

/* =====================================================================
   E) ¿LOS INDICES NUEVOS AFECTAN LAS ESCRITURAS? (sp_VenderBoleto)
   Vende 300 boletos reales con el procedimiento dentro de una transaccion
   que se REVIERTE al final (no deja datos). Se mide con y sin los 3
   indices de lectura nuevos (los deshabilitados no se mantienen en INSERT).
   Requiere haber ejecutado 02_sp_VenderBoleto.sql.
   ===================================================================== */
SET NOCOUNT ON;
ALTER INDEX IX_Boletos_ClienteID         ON dbo.Boletos DISABLE;
ALTER INDEX IX_Boletos_Estado_FechaVenta ON dbo.Boletos DISABLE;
ALTER INDEX IX_Pagos_BoletoID            ON dbo.Pagos   DISABLE;
GO
-- E.1 SIN indices de lectura
SET NOCOUNT ON;
DECLARE @N INT = 300, @i INT = 1, @V INT, @A INT, @B INT, @t0 DATETIME2 = SYSDATETIME();
IF OBJECT_ID('tempdb..#Cand') IS NOT NULL DROP TABLE #Cand;
SELECT TOP (@N) ROW_NUMBER() OVER (ORDER BY v.ViajeID, s.NumeroAsiento) AS rn, v.ViajeID, s.NumeroAsiento
INTO #Cand
FROM dbo.Viajes v JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.Estado = 'Programado'
  AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b WHERE b.ViajeID = v.ViajeID
                  AND b.NumeroAsiento = s.NumeroAsiento AND b.Estado = 'Activo')
ORDER BY v.ViajeID, s.NumeroAsiento;
BEGIN TRANSACTION;
WHILE @i <= @N
BEGIN
    SELECT @V = ViajeID, @A = NumeroAsiento FROM #Cand WHERE rn = @i;
    EXEC dbo.sp_VenderBoleto @ViajeID = @V, @NumeroAsiento = @A, @ClienteID = 1,
         @Canal = 'Web', @Metodo = 'Tarjeta', @BoletoID = @B OUTPUT;
    SET @i += 1;
END
SELECT 'SIN indices de lectura' AS Escenario, @N AS Ventas,
       DATEDIFF(MILLISECOND, @t0, SYSDATETIME()) AS Ms_Total;
ROLLBACK TRANSACTION;
GO
ALTER INDEX IX_Boletos_ClienteID         ON dbo.Boletos REBUILD;
ALTER INDEX IX_Boletos_Estado_FechaVenta ON dbo.Boletos REBUILD;
ALTER INDEX IX_Pagos_BoletoID            ON dbo.Pagos   REBUILD;
GO
-- E.2 CON indices de lectura
SET NOCOUNT ON;
DECLARE @N INT = 300, @i INT = 1, @V INT, @A INT, @B INT, @t0 DATETIME2 = SYSDATETIME();
IF OBJECT_ID('tempdb..#Cand') IS NOT NULL DROP TABLE #Cand;
SELECT TOP (@N) ROW_NUMBER() OVER (ORDER BY v.ViajeID, s.NumeroAsiento) AS rn, v.ViajeID, s.NumeroAsiento
INTO #Cand
FROM dbo.Viajes v JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.Estado = 'Programado'
  AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b WHERE b.ViajeID = v.ViajeID
                  AND b.NumeroAsiento = s.NumeroAsiento AND b.Estado = 'Activo')
ORDER BY v.ViajeID, s.NumeroAsiento;
BEGIN TRANSACTION;
WHILE @i <= @N
BEGIN
    SELECT @V = ViajeID, @A = NumeroAsiento FROM #Cand WHERE rn = @i;
    EXEC dbo.sp_VenderBoleto @ViajeID = @V, @NumeroAsiento = @A, @ClienteID = 1,
         @Canal = 'Web', @Metodo = 'Tarjeta', @BoletoID = @B OUTPUT;
    SET @i += 1;
END
SELECT 'CON indices de lectura' AS Escenario, @N AS Ventas,
       DATEDIFF(MILLISECOND, @t0, SYSDATETIME()) AS Ms_Total;
ROLLBACK TRANSACTION;
GO

/* CONCLUSION (adaptar con sus numeros):
   Cada indice adicional se mantiene en cada INSERT: sp_VenderBoleto inserta
   1 fila en Boletos (ahora en 3 indices: UX, ClienteID, Estado/FechaVenta) y
   1 en Pagos (2 indices). El costo medido es de X ms por cada 300 ventas
   (~Y ms por venta), irrelevante frente a la mejora de las lecturas
   (miles de lecturas logicas -> unas pocas). Aun asi, no conviene agregar
   indices "por si acaso": cada uno ocupa espacio y penaliza las escrituras.
   El indice UX_Boletos_Viaje_Asiento_Activo ademas AYUDA a sp_VenderBoleto:
   su verificacion con UPDLOCK/HOLDLOCK hace un seek en lugar de un scan,
   bloqueando solo el rango del asiento y no toda la tabla. */
