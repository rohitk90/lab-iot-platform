# onboarding/onboard.py
import sys
import yaml
from pathlib import Path

def generate_edge_config(config_path):
    """
    Parses a human-readable system configuration YAML file and generates
    the corresponding edge telegraf.conf configuration block out of it.
    """
    try:
        with open(config_path, 'r') as file:
            config = yaml.safe_load(file)
    except FileNotFoundError:
        print(f"❌ Error: Configuration file not found at '{config_path}'")
        sys.exit(1)
    except yaml.YAMLError as e:
        print(f"❌ Error parsing YAML configuration sheet layout: {e}")
        sys.exit(1)
    
    # Extract structural layout dictionaries
    asset = config.get('asset', {})
    plc = config.get('plc', {})
    tags = config.get('tags', [])

    if not asset or not plc or not tags:
        print("❌ Error: Missing mandatory fields ('asset', 'plc', or 'tags') in YAML.")
        sys.exit(1)
    
    print(f"Reading profile for: {asset.get('name', 'Unknown Asset')}")
    output_path = Path(f"./telegraf_{asset.get('id', 'unknown')}.conf")
    
    try:
        with open(output_path, 'w') as f:
            # Write agent baseline parameters wrapper
            f.write("[agent]\n")
            f.write('  interval = "1s"\n')
            f.write("  round_interval = true\n")
            f.write("  metric_batch_size = 1000\n")
            f.write("  metric_buffer_limit = 10000\n")
            f.write('  flush_interval = "1s"\n')
            f.write('  precision = "1ms"\n')
            f.write(f'  hostname = "edge-pi-{asset.get("id", "dev")}"\n\n')

            # Write the Siemens s7comm input block details
            f.write("[[inputs.s7comm]]\n")
            f.write(f'  server = "{plc.get("ip_address", "127.0.0.1")}"\n')
            f.write(f'  port = {plc.get("port", 102)}\n')
            f.write("  fields = [\n")
            
            for tag in tags:
                # Dynamically evaluate target metrics parsing type primitives
                s7_type = "real" if tag.get('data_type') == "float" else "bool"
                f.write(f'    {{ name = "{tag.get("name")}", address = "{plc.get("data_block")}.{tag.get("address_offset")}", type = "{s7_type}" }},\n')
                
            f.write("  ]\n")
            f.write("  [inputs.s7comm.tags]\n")
            f.write(f'    asset_id = "{asset.get("id")}"\n\n')

            # Write the standard MQTT output distribution engine wrapper
            f.write("[[outputs.mqtt]]\n")
            f.write('  servers = ["tcp://10.0.1.190:1883"]\n')
            f.write(f'  topic_prefix = "lab/{asset.get("id")}/telemetry"\n')
            f.write('  data_format = "json"\n')
            
        print(f"🎉 Success! Custom Telegraf edge configuration generated at:\n   ➡️ {output_path.resolve()}")
        print("\nCopy this file content onto the plant-floor Raspberry Pi 5 node.")
        print("The central database will auto-discover and auto-register it instantly upon boot!")
        
    except Exception as e:
        print(f"❌ Critical Error generating configuration files: {e}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python onboard.py <path_to_config_yaml>")
        sys.exit(1)
        
    generate_edge_config(sys.argv[1])
