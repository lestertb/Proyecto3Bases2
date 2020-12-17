--------------------------------------------------------------------NodoLocal--------------------------------------------------------------------
--Crear base de datos
CREATE DATABASE nodolocalproyecto3db2;

--Se crea la extensión postgis
CREATE EXTENSION postgis;

--Tabla empresas
CREATE TABLE empresa(
	id_empresa INT PRIMARY KEY,
	nombre VARCHAR (50) NOT NULL,
	correo VARCHAR (50) UNIQUE,
	departamentos JSON NOT NULL
);

--Se le agrega la columna Geometry a la tabla empresa
SELECT AddGeometryColumn ('public','empresa','geom',4326,'POINT',2,true);

--Tabla empleado
CREATE TABLE empleado(
	id_empleado SERIAL PRIMARY KEY,
	nombre VARCHAR (50) NOT NULL,
	apellido1 VARCHAR (50) NOT NULL,
	apellido2 VARCHAR (50) NOT NULL,
	fecha_nacimiento DATE,
	estado_civil VARCHAR (50) NULL,
	genero CHAR(1),
	id_empresa INT NOT NULL,
	CONSTRAINT fk_empresa FOREIGN KEY (id_empresa) REFERENCES empresa (id_empresa)
);

--Tabla de telefono de la empresa con sus extensiones
CREATE TABLE telefonos(
	id_empresa INT PRIMARY KEY,
	num_telefono VARCHAR(20),
	extensiones JSON NULL,
	FOREIGN KEY (id_empresa) REFERENCES empresa
);

--Inserciones de ejemplo
--Empresas
INSERT INTO empresa VALUES (1,'Empresa1','correo@empresa1.com','{"nombre":"Contabilidad"}'::JSON);
INSERT INTO empresa VALUES (2,'Empresa2','correo@empresa2.com','{"nombre":"RRHH"}'::JSON);
SELECT * FROM empresa;
--Telefono de empresa
INSERT INTO telefonos VALUES (1,'123456789','{"ext":"123"}'::JSON);
INSERT INTO telefonos VALUES (2,'987654321','{"ext":"321"}'::JSON);
SELECT * FROM telefonos;
--Empleado
INSERT INTO empleado VALUES ('nombreEmpleado1','apellido1Empleado1','apellido2Empleado1','2020-12-14','Soltero','F',1);
INSERT INTO empleado VALUES ('nombreEmpleado2','apellido1Empleado2','apellido2Empleado2','2020-12-14','Soltero','M',2);
SELECT * FROM empleado;

--Vista para ver solo los datos del nodoLocal 
CREATE OR REPLACE VIEW vista_empresasnodolocal
AS
	SELECT empr.*,tel.num_telefono,tel.extensiones,
	empl.nombre AS nombre_empleado,empl.apellido1,empl.apellido2,empl.fecha_nacimiento,empl.estado_civil,empl.genero
	FROM empresa AS empr
	INNER JOIN telefonos AS tel ON (empr.id_empresa=tel.id_empresa) 
	INNER JOIN empleado AS empl ON (empr.id_empresa=empl.id_empresa)

SELECT * FROM vista_empresasnodolocal

--Función que actualiza en el nodo local segun los valores que llegan de QGIS
CREATE OR REPLACE FUNCTION update_vista_empresasnodolocal()
    RETURNS trigger
    LANGUAGE 'plpgsql'
	AS 
	$BODY$
		BEGIN
			UPDATE empresa SET nombre=NEW.nombre, correo=NEW.correo, departamentos=NEW.departamentos, geom=NEW.geom WHERE id_empresa=NEW.id_empresa;
			UPDATE telefonos SET num_telefono=NEW.num_telefono, extensiones=NEW.extensiones WHERE id_empresa=NEW.id_empresa;
			UPDATE empleado SET nombre=NEW.nombre_empleado, apellido1=NEW.apellido1, apellido2=NEW.apellido2, fecha_nacimiento=NEW.fecha_nacimiento, estado_civil=NEW.estado_civil, genero=NEW.genero WHERE id_empresa=NEW.id_empresa; 
		RETURN NEW;
		END;
	$BODY$;

CREATE TRIGGER trigger_update_vista_empresasnodolocal
	INSTEAD OF insert or update or delete
	ON  vista_empresasnodolocal
	FOR EACH ROW
	EXECUTE PROCEDURE update_vista_empresasnodolocal();

--------------------------------------------------------------------ConexionNodoCentral--------------------------------------------------------------------

-----------------------------------------Creacion de la conexion remota-----------------------------------------

--instalación de librería dblink
CREATE EXTENSION dblink;

--creación de usuario quien tendrá privilegios de usar el servidor vinuclado.
CREATE USER remote_user WITH PASSWORD 'admin';

--Creación de servidor remoto

CREATE SERVER leoviquez_b2p3
FOREIGN DATA WRAPPER dblink_fdw
OPTIONS (host 'leoviquez.com', dbname 'p3_empresas', port '5432');

--Asignación de usuario de acceso remoto
CREATE USER MAPPING FOR remote_user
SERVER leoviquez_b2p3
OPTIONS (user 'basesII', password '12345');

--Asignación de privilegios al servidor remoto
GRANT USAGE ON FOREIGN SERVER leoviquez_b2p3 TO remote_user;

-----------------------------------------Obtener datos de la conexion remota prueba-----------------------------------------
select dblink_connect('myconn', 'leoviquez_b2p3');
select dblink('myconn','begin');

select * from dblink('myconn','select id,nombre from s_data.empresas') AS t(id int,name VARCHAR);

select c.id,c.nombre,el.nombre from vista_empresasnodolocal el right outer join (
	select * 
	from dblink('myconn','select id,nombre from s_data.empresas') 
	as respuesta(id int,nombre varchar)) c on (el.id_empresa=c.id)

select dblink_disconnect('myconn');
-----------------------------------------Stored Procedure para insertar local y remoto-----------------------------------------

------------------------------------------------------------------------->Updates<------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION insert_vista_empresas()
    RETURNS trigger
    LANGUAGE 'plpgsql'
	AS 
	$BODY$
	Declare
		sql varchar(2000);
		detalles varchar(500);
		id_empresa int;
		valor_innecesario int;
	BEGIN
		perform dblink_connect('myconn', 'leoviquez_b2p3');

		perform dblink('myconn','begin');

		sql := 'SELECT crea_empresa (''' || new.nombre || ''','''||st_astext(new.geom)||''',''P3B2ALM'',''P3B2ALM'')';
		select * into id_empresa from dblink('myconn',sql) as respuesta(id int);
		raise notice 'Empresa registrada en el servidor central (id:%)',id_empresa;

		detalles := json_build_object('departamentos',new.departamentos,'extensiones',new.extensiones);
		sql := 'SELECT registra_caracteristicas ('||id_empresa||','''|| detalles ||''',''P3B2ALM'',''P3B2ALM'')';
		select * into valor_innecesario from dblink('myconn',sql) as result(respuesta int);
		raise notice 'Detalles de empresa registrados en el servidor central';

		insert into empresas (id,nombre,geom) values (id_empresa,NEW.nombre,NEW.geom);
		insert into empleado (nombre_empleado,
							  apellido1,
							  apellido2,
							  fecha_nacimiento,
							  estado_civil,
							  genero,
							  id_empresa) 
							  values (
								  NEW.nombre_empleado,
								  NEW.apellido1,
								  NEW.apellido2
								  NEW.fecha_nacimiento,
								  NEW.estado_civil,
								  NEW.genero,
								  id_empresa);

		perform dblink_exec('myconn','end;');
		perform dblink_disconnect('myconn');

	RETURN NEW;
	END;
	$BODY$;

CREATE TRIGGER trigger_insert_vista_empresasnodolocal
	INSTEAD OF insert or update or delete
	ON  vista_empresasnodolocal
	FOR EACH ROW
	EXECUTE PROCEDURE insert_vista_empresas();


