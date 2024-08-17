import requests

def send_url_to_server(url):
    """Send a URL to the server and display the response in a user-friendly format."""
    try:
        response = requests.post("http://localhost:4567/analyze", data={'url': url})
        if response.status_code == 200:
            print("Server Response:")
            print("-" * 40)
            print(response.text.strip())
            print("-" * 40)
        else:
            print(f"Error occurred while sending the request. Response code: {response.status_code}")
    except Exception as e:
        print(f"An error occurred: {e}")

def main():
    """Main function to prompt the user for URLs and send them to the server."""
    print("Enter a URL to analyze (or type 'exit' to quit):")
    while True:
        url = input("URL: ").strip()
        if url.lower() == 'exit':
            print("Exiting...")
            break
        if url:
            send_url_to_server(url)
        else:
            print("Please enter a valid URL.")

if __name__ == "__main__":
    main()
