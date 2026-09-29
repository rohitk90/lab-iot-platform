# onboarding/onboard.py
import os
import sys
import yaml
import psycopg2
from pathlib import Path

def onboard_system(config_path):
    # 1. Fetch credentials securely from the server environment variables
    db_name = os.getenv("POSTGRES_DB")
    db_user = os.getenv("POSTGRES_USER")
    db_password = os.getenv("POSTGRES_PASSWORD")
    db_host = os.getenv("DB_HOST", "localhost")  # Defaults to localhost if run directly on server
    db_port = os.getenv("DB_PORT", "5432")

    # Guard clause: Verify environment parameters are active
    if not all([db_name, db_user, db_password]):
        print("❌ Critical Error: Database environment variables are missing.")
        print("   Ensure you have sourced your .env file or run this within the platform network.")
        sys.exit(1)

    # Construct connection string dynamically
    db_connection_string = f"host={db_host} port={db_port} dbname={db_name} user={db_user} password={db_password}"

    # 2. Parse the standard human-readable YAML configuration file
    try:
        with open(config_path, 'r') as file:
            config = yaml.safe_load(file)
    except FileNotFoundError:
        print(f"❌ Error: Configuration file not found at '{config_path}'")
        sys.exit(1)
    except yaml.YAMLError as e:
        print(f"❌ Error parsing YAML layout: {e}")
        sys.exit(1)
    
    asset = config['asset']
    tags = config['tags']
    plc = config['plc']
    
    print(f"Connecting to database securely to onboard: {asset['name']}...")
    
    try:
        conn = psycopg2.connect(db_connection_string)
        cursor = conn.cursor()
        
        # 3. Automatically register the Asset metadata
        cursor.execute("""
            INSERT INTO platform_data.assets (asset_id, asset_name, location_zone)
            VALUES (%s, %s, %s)
            ON CONFLICT (asset_id) DO UPDATE SET 
                asset_name = EXCLUDED.asset_name, 
                location_zone = EXCLUDED.location_zone;
        """, (asset['id'], asset['name'], asset['location_zone']))
        
        # 4. Automatically register all parameter strings inside the Tag table
        for tag in tags:
            tag_composite_id = f"{asset['id']}.{tag['name']}"
            tag_display_name = f"{tag['description']} ({tag['name']})"
            
            cursor.execute("""
                INSERT INTO platform_data.asset_tags (tag_id, asset_id, tag_name, data_type)
                VALUES (%s, %s, %s, %s)
                ON CONFLICT (tag_id) DO UPDATE SET 
                    tag_name = EXCLUDED.tag_name, 
                    data_type = EXCLUDED.data_type;
            """, (tag_composite_id, asset['id'], tag_display_name, tag['data_type']))
            
        conn.commit()
        print("🎉 Database metadata profiles registered successfully!")
        
        # 5. Generate the corresponding Telegraf Configuration block automatically
        generate_telegraf_config(asset, plc, tags)
        
    except Exception as e:
        if 'conn' in locals() and conn:
            conn.rollback()
        print(f"❌ Critical Error onboarding system: {e}")
    finally:
        if 'cursor' in locals() and cursor:
            cursor.close()
        if 'conn' in locals() and conn:
            conn.close()

def generate_telegraf_config(asset, plc, tags):
    output_path = Path(f"./telegraf_{asset['id']}.conf")
    
    with open(output_path, 'w') as f:
        f.write("[[inputs.s7comm]]\n")
        f.write(f'  server = "{plc["ip_address"]}"\n')
        f.write(f'  port = {plc["port"]}\n')
        f.write("  fields = [\n")
        
        for tag in tags:
            s7_type = "real" if tag['data_type'] == "float" else "bool"
            f.write(f'    {{ name = "{tag["name"]}", address = "{plc["data_block"]}.{tag["address_offset"]}", type = "{s7_type}" }},\n')
            
        f.write("  ]\n")
        f.write("  [inputs.s7comm.tags]\n")
        f.write(f'    asset_id = "{asset["id"]}"\n')
        
    print(f"📝 Custom Telegraf edge configuration generated at: {output_path.resolve()}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python onboard.py <path_to_config_yaml>")
        sys.exit(1)
        
    onboard_system(sys.argv[1])
